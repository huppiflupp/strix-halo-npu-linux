# Hardware profile of the test machine

Everything in this repo was measured on this one box. Values below were read
from the running system on 2026-09-18 (sysfs, `lspci`, `lscpu`, `xrt-smi`,
`vulkaninfo`) unless marked *spec*, which means manufacturer data I could not
read back without root.

## System

| | |
|---|---|
| Machine | GMKtec NucBox EVO-X2 (mini PC) |
| Firmware | AMI, BIOS `EVO-X2 1.05` (2025-06-06) |
| OS | Nobara Linux 44 (Fedora 44 base), KDE Plasma |
| Kernel | `7.2.0-202.nobara.fc44.x86_64` |

## SoC: AMD Ryzen AI Max+ 395 "Strix Halo"

| | |
|---|---|
| CPU | 16 Zen 5 cores / 32 threads, 625 MHz – 5.19 GHz |
| Caches | L1d 48 KiB/core, L2 1 MiB/core (16 MiB), L3 64 MiB (2 × 32 MiB, one per CCD) |
| ISA extras | full AVX-512 incl. `avx512_bf16`, `avx512_vnni`, `vp2intersect`; `avx_vnni`. No AMX. |
| iGPU | Radeon 8060S, gfx1151, PCI `1002:1586`; shader clock up to 2.9 GHz |
| NPU | XDNA2, PCI `1022:17f0`, firmware `1.1.2.65` |

## Memory: unified, no real VRAM

| | |
|---|---|
| Installed | 128 GB LPDDR5X (*spec*: 8000 MT/s, 256-bit), 125 GiB visible to Linux |
| VRAM carve-out | 512 MiB (`mem_info_vram_total`), set in firmware, deliberately minimal |
| GPU-reachable (GTT) | 120 GiB, via `ttm.pages_limit=31457280 ttm.page_pool_size=31457280` |

The iGPU works almost entirely out of GTT, i.e. ordinary system RAM. Two things
follow that trip people up:

- `rocm-smi`'s "VRAM" figure shows the 512 MiB carve-out, not what the GPU can
  use. Read `mem_info_gtt_used` instead.
- CPU, iGPU and NPU share one memory controller. A workload that is bandwidth
  bound gains nothing by moving to another compute unit, and a GPU "tier" that
  keeps a second copy of weights costs bandwidth instead of saving it (measured
  in colibri, −37 % decode with the GPU expert tier on this APU vs +101 % on a
  discrete RTX 5080).

## Storage

| | |
|---|---|
| NVMe | Lexar ARES 2 TB (Longsys controller, DRAM-less), PCIe 4.0 x4 (16 GT/s) |
| Filesystem | btrfs (`/` and `/home` are subvolumes of the same partition) |
| Measured | 4.45 GB/s buffered, 6.61 GB/s `O_DIRECT` (random 19 MB reads) |

Only one M.2 slot is populated.

## I/O

| | |
|---|---|
| USB4 | **2 × USB4 host routers** (`1022:158d`, `1022:158e`), both report generation 4 = USB4 at 40 Gbit/s. Thunderbolt 3/4 devices work through them. **Not Thunderbolt 5 / USB4 v2 (80 Gbit/s).** `boltctl` security level `iommu+user`. |
| USB 3.x | 4 × xHCI controllers (`1022:1587/1588/1589/158b`) |
| Ethernet | Realtek RTL8125, 2.5 GbE |
| Wi-Fi | MediaTek MT7925 (Wi-Fi 7, 160 MHz) |
| Display | the kernel exposes 1 × HDMI and 8 DP connectors (DRM connector count, not physical sockets) |

To check the USB4 generation yourself:

```bash
cat /sys/bus/thunderbolt/devices/*-0/generation    # 4 = USB4, 3 = TB3
boltctl domains
```

## Power

- No per-rail sensors apart from:
  - `amdgpu` hwmon `power1_input`, labelled **PPT**. That is the socket
    (package) power of the whole SoC, not just the GPU.
  - RAPL `intel-rapl:0` (package) and `intel-rapl:0:0` (cores) via
    `/sys/class/powercap`, world-readable on this kernel.
- **The NPU has no power sensor of its own.** `xrt-smi examine -r platform`
  fails with `DRM_IOCTL_AMDXDNA_GET_INFO ... err=-95` on the in-tree driver, so
  NPU power can only be inferred as a delta of the socket figure against idle.
- Spot reading: ~85 W PPT with all 32 threads busy on a CPU-bound workload.
- No `platform_profile` in ACPI. GPU DPM on `auto`.

## Software stack

| component | version |
|---|---|
| Mesa / RADV | 26.2.1 (Vulkan 1.4.354), LLVM 22.1.8 |
| ROCm / HIP | 7.1.52802 |
| XRT | 2.26.0 (`c826a0ef`, 2026-09-01) |
| NPU driver | in-tree `amdxdna` of kernel 7.2 (see README: faster than DKMS) |
| Ollama | 0.34.1 |
| Lemonade Server | 11.6.0 (llama.cpp on the iGPU, FastFlowLM on the NPU) |

## NPU at a glance

- `xrt-smi validate`: 51 TOPS (gemm), 56 µs latency, ~94 k op/s
- Gemma 4 E4B decode: 12.4 tok/s on the NPU vs ~54–69 tok/s on the iGPU (same
  weights family; see README and MODELS.md). The iGPU is 4.5–5.6x faster.
- Energy per token was never measured. That is the open question now (colibri
  discussion [#1590](https://github.com/JustVugg/colibri/discussions/1590)).
