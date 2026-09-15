# AMD NPU (XDNA) on Nobara Linux

Notes and a reproducible setup script for getting the AMD Ryzen AI NPU
(XDNA / amdxdna) working on Nobara Linux, built from
[amd/xdna-driver](https://github.com/amd/xdna-driver).

## Tested on

- Nobara Linux 44 (Fedora 44 base), kernel `7.1.4-200.nobara.fc44.x86_64`
- AMD Ryzen AI Max+ 395 "Strix Halo" (NPU PCI id `1022:17f0`, XDNA2)
- Result: `xrt-smi validate` passes — 51 TOPS (gemm), 56us latency, ~94k op/s throughput

## Why this isn't a one-liner

The upstream repo supports Ubuntu/Debian, Arch, and Fedora out of the box.
Nobara is Fedora-based (`ID_LIKE=... fedora` in `/etc/os-release`) but
`ID=nobara`, and several places in the build tooling do exact string
matches on `ID` rather than checking `ID_LIKE`. That breaks flavor
detection in two places:

1. `tools/amdxdna_deps.sh` → `xrtdeps.sh`: doesn't recognize `nobara` as a
   flavor at all, and its Fedora dependency list includes `redhat-lsb`,
   which conflicts with Nobara's own `lsb_release` package.
2. `xrt/src/CMake/nativeLnx.cmake`: sets `LINUX_FLAVOR` from `ID` only, so
   XRT's own CPack config falls through to a `TGZ`-only package instead of
   building RPMs. (The driver plugin's own `CMake/pkg.cmake`, by contrast,
   already checks `ID_LIKE` too and works unpatched.)

Also: `build.sh` runs with `set -e`, and by default runs the aiebu
submodule's CTest suite after building XRT. One test in that suite
(`aie2ps_eff_net_coal_compareelf`) fails on this setup (153/154 pass) —
unrelated to actual NPU function, but enough to abort the script before
packaging. Build with `-noctest` to skip it.

## What's in this repo

- `setup.sh` — clones `amd/xdna-driver`, applies the patch, installs deps,
  builds XRT + the XDNA plugin, installs the RPMs, and sets up memlock
  limits. Safe to re-run (skips the clone if the dir already exists).
- `benchmark.sh` — re-runnable speed/correctness snapshot across the 5
  models/backends and Hermes tool-calling documented below. ~4 min. Run
  it after any driver/model/config change to get numbers, not vibes.
- `patches/0001-nobara-flavor-as-fedora.patch` — treats `nobara` as
  `fedora` in XRT's native Linux CMake flavor detection.
- `config/99-amdxdna.limits.conf` → installed to
  `/etc/security/limits.d/99-amdxdna.conf`
- `config/99-amdxdna-memlock.service.conf` → installed to
  `/etc/systemd/system/user@.service.d/99-amdxdna-memlock.conf`
- `config/10-allowed-origins.conf` → installed to
  `/etc/lemonade/conf.d/10-allowed-origins.conf` (only needed if exposing
  Lemonade Server's web UI to the LAN, see below)

Both memlock configs are needed on Fedora/Nobara: without them, NPU BO
allocation fails with `mmap(...) failed (err=-11): Resource temporarily
unavailable` because the default locked-memory limit (8MB) is too low.
The systemd override only takes effect in a new login session — log out
and back in (or reboot) after running the script.

## Usage

```
git clone <this-repo>
cd nobara-amd-npu-setup
./setup.sh
```

Then log out/in (or reboot), and:

```
source /opt/xilinx/xrt/setup.sh
xrt-smi examine
xrt-smi validate
```

## Secure Boot

DKMS signs `amdxdna.ko` with a self-generated MOK key
(`/var/lib/dkms/mok.key` / `mok.pub`). If Secure Boot is enabled, you'll
need to enroll that key with `mokutil --import` and reboot, or the signed
module will fail to load. This system has Secure Boot disabled, so that
step wasn't needed/tested here.

## Known-good build versions

- XRT: `2.26.0`
- XDNA plugin: `2.26.1` (built from a commit checked out on 2026-08-16)
- NPU firmware: `1.1.2.65`

xdna-driver is under active development; a later checkout may behave
differently. If `setup.sh` fails on a later checkout, compare against the
upstream `README.md` for what changed.

## Running LLMs on the NPU (Lemonade Server + FastFlowLM)

Once XRT/amdxdna is installed and validated above, [Lemonade
Server](https://lemonade-server.ai/) (an OpenAI-compatible local LLM
server) can use the NPU via its `flm:npu` backend
([FastFlowLM](https://fastflowlm.com/)).

```
# Fedora 44 RPM (Nobara 44 is Fedora-44-based, works unpatched)
gh release download --repo lemonade-sdk/lemonade --pattern "lemonade-server-*-fc44.x86_64.rpm"
sudo dnf install ./lemonade-server-*-fc44.x86_64.rpm
sudo systemctl enable --now lemond

lemonade backends install flm:npu       # NPU backend (FastFlowLM)
lemonade backends install llamacpp:vulkan  # iGPU backend, for comparison

lemonade pull gemma4-it-e4b-FLM         # NPU-format model
lemonade pull Gemma-4-E4B-it-GGUF       # same model, GGUF, for iGPU
```

Server runs at `http://localhost:13305` (OpenAI-compatible `/api/v1/chat/completions`).

Unlike the xdna-driver build, this RPM installed and worked without any
Nobara-specific patching.

### NPU vs iGPU benchmark (2026-08-16)

Same model (Gemma 4, ~4B active params), same prompts, on this machine
(Ryzen AI Max+ 395 / Radeon 8060S):

| | NPU (`flm:npu`, FastFlowLM, q4nx quant) | iGPU (`llamacpp:vulkan`, GGUF Q4_K_M) |
|---|---|---|
| Decode speed | ~12.0 tok/s | ~53.6 tok/s |
| Prefill speed | 15.9–26.9 tok/s | 62–235 tok/s |
| 600 tokens, wall time | ~52s | ~11.5s |

**The iGPU is ~4.5x faster for raw throughput.** Not a hardware-apples-to-
apples comparison (different quantization + different runtimes), but it's
what's actually available today. Strix Halo's iGPU has real memory
bandwidth behind it; the NPU here is optimized for power efficiency at
lower/background load, not peak tokens/s. Power draw wasn't measured in
this pass — that's the NPU's actual selling point and remains untested.

**Practical takeaway:** for interactive/latency-sensitive local inference
(e.g. an extraction pipeline built around a local model), prefer the iGPU
backend (`llamacpp:vulkan`) on this hardware. The NPU is more interesting
when the iGPU is busy with something else (display output, a game) or for
low-power background inference.

### Decode speed tracks active params, not total size or backend (2026-08-16)

Tested `gpt-oss-20b-FLM` (21B total, ~3.6B active, MoE) and
`qwen3.6-moe-35b-a3b-FLM` (35B total, ~3B active, MoE) on the NPU, plus
`qwen3.8:latest` (18B, dense, no MoE) on the iGPU via Ollama — same
prompts as above:

| Model | Backend | Size | Decode | Prefill |
|---|---|---|---|---|
| gemma4-it-e4b-FLM | NPU (flm) | ~9GB, 4B active | 12.0 tok/s | 15.9–26.9 tok/s |
| gpt-oss-20b-FLM | NPU (flm) | 14GB, ~3.6B active | **19.3 tok/s** | 21.8–26.3 tok/s |
| qwen3.6-moe-35b-a3b-FLM | NPU (flm) | 35GB, ~3B active | 13.4 tok/s | 6.9 tok/s |
| Gemma-4-E4B-it-GGUF | iGPU (vulkan) | 5.6GB, 4B active | 53.6 tok/s | 62–235 tok/s |
| qwen3.8:latest | iGPU (Ollama, 18GB) | 18GB, **dense** | 15.9 tok/s | 80.5 tok/s |

Takeaways:
- On the NPU, `gpt-oss-20b` (fewer active params) decodes ~60% faster
  than `gemma4-e4b` despite being a much bigger download — **NPU decode
  speed tracks active params per token, not model/download size.**
- `qwen3.6-moe`'s prefill (6.9 tok/s) is much worse than the others
  despite similar active-param count — likely because prefill still has
  to touch a lot of the 35GB of expert weights for routing, so it's more
  bandwidth-bound than decode is.
- `qwen3.8` (dense, all 18B active every token) on the iGPU decodes at
  15.9 tok/s — barely faster than the *NPU* MoE models, and nowhere near
  the 53.6 tok/s of the iGPU-hosted MoE Gemma4. Architecture (MoE vs.
  dense) matters more here than which engine (NPU vs iGPU) runs it — this
  is not an apples-to-apples NPU-vs-iGPU comparison, model choice
  dominates.

**Running NPU (flm) and iGPU (Ollama/vulkan) models loaded simultaneously
is fine, memory-wise, on this machine:** `qwen3.6-moe-35b-a3b-FLM` (29.5GB
RSS) + `qwen3.8:latest` (18GB, 100% GPU) loaded at the same time still
left ~19GB available (62GB total unified memory), no swap used. NPU and
iGPU are separate compute engines on Strix Halo, so this is genuine
parallelism, not just memory coexistence — though both draw on the same
LPDDR5X bandwidth, which could become the shared bottleneck if both are
generating heavily at once (not measured).

## Lemonade as a backend for other tools (Hermes)

Lemonade's OpenAI-compatible API (`http://127.0.0.1:13305/api/v1`) plugs
into anything that takes a custom OpenAI-compatible provider — e.g. the
[Hermes agent](https://github.com/NousResearch) at `~/.hermes/`, via a new
entry under `providers:` in `~/.hermes/config.yaml` (same shape as the
existing `ollama-launch` entry):

```yaml
providers:
  lemonade-npu:
    api: http://127.0.0.1:13305/api/v1
    default_model: gemma4-it-e4b-FLM
    models:
      - gemma4-it-e4b-FLM
      - gpt-oss-20b-FLM
    name: Lemonade NPU
```

Use with `hermes --provider lemonade-npu -m <model>`, or set as the
persistent default via `hermes model` (interactive picker).

**Gotcha: not every FLM model supports tool-calling.** Lemonade's
`/api/v1/models` reports capability labels per model — `gemma4-it-e4b-FLM`
has `tool-calling` in its labels, `gpt-oss-20b-FLM` does not. Verified by
asking each, via Hermes, to run a shell command with an unguessable
result (`hostname && id -u`): `gemma4-it-e4b-FLM` returned the real
values; `gpt-oss-20b-FLM` said "I don't have access to your actual
shell" and fabricated a plausible-looking fake result instead — it
degrades silently rather than erroring, which is the dangerous part. For
an agent that leans on tool-calling, check the `labels` field before
picking a `default_model`, don't assume every chat-capable model works.

**Set as Hermes's persistent default (2026-08-17):** beyond the
`providers:` entry above, the top-level `model:` block in
`~/.hermes/config.yaml` controls what bare `hermes` (no `--provider`/`-m`)
actually uses:

```yaml
model:
  api_key: lemonade
  base_url: http://127.0.0.1:13305/api/v1
  default: gemma4-it-e4b-FLM
  provider: lemonade-npu
```

Previously this pointed at Ollama (`qwen3.8` via `ollama-launch`), which
stays configured and available — switch back anytime with `hermes model`
(interactive picker) or by editing this block. `~/.hermes/config.yaml`
itself isn't in this repo (it's the user's live agent config, not
NPU-setup infrastructure); this snippet is the reproducible recipe.
`gemma4-it-e4b-FLM` was picked over `gpt-oss-20b-FLM` specifically
because it's the one that actually tool-calls (see gotcha above) — don't
flip the default to `gpt-oss-20b-FLM` without fixing that first.

## Is NPU+iGPU hybrid execution (one model, split prefill/decode) possible on Linux?

Researched 2026-08-16: **no, and there's no public roadmap for it.**

`ryzenai-llm` — the Lemonade backend that would do this — is hardcoded
Windows-only in Lemonade's backend descriptor
(`src/cpp/include/lemon/backends/ryzenai/ryzenai.h`: `{"npu", {"windows"}}`).
The underlying wrapper, [lemonade-sdk/ryzenai-server](https://github.com/lemonade-sdk/ryzenai-server),
does have Linux build instructions and links against AMD's closed-source
Ryzen AI Software runtime — but AMD's own docs
([ryzenai.docs.amd.com/en/latest/linux.html](https://ryzenai.docs.amd.com/en/latest/linux.html))
say plainly: **"Linux currently supports NPU only flow"**. The hybrid
prefill/decode-split execution provider itself isn't shipped for Linux at
all — this is a closed-runtime gap, not a driver/packaging one. No ETA is
stated in the relevant open issues
([amd/RyzenAI-SW#313](https://github.com/amd/RyzenAI-SW/issues/313),
[#265](https://github.com/amd/RyzenAI-SW/issues/265),
[#333](https://github.com/amd/RyzenAI-SW/issues/333)), and the Linux
build of Ryzen AI Software itself requires AMD "early access" registration.

**DIY:** real hybrid execution (one ONNX graph, NPU+iGPU split) isn't
buildable ourselves — it needs AMD's closed compiler/runtime internals,
unavailable on Linux. A hand-rolled pseudo-hybrid (FastFlowLM does
prefill on NPU, hand the KV-cache to llama.cpp for iGPU decode) is
conceivable but would mean building a translation layer between two
incompatible KV-cache formats — a multi-week project with no guaranteed
payoff. Not pursued. `flm:npu` (NPU-only) remains the best available
option on Linux for now.

## Standalone FastFlowLM CLI (`flm`)

Independent of Lemonade's bundled `flm:npu` backend binary, the official
[FastFlowLM](https://github.com/FastFlowLM/FastFlowLM) project also ships
a portable, self-contained Linux tarball (own `flm`/`flm-real` binary +
bundled XRT libs, doesn't touch the system XRT install) — no Fedora/Nobara
package exists, but the portable build needs no distro-specific patching:

```
gh release download --repo FastFlowLM/FastFlowLM --pattern "fastflowlm_*_linux.tar.gz"
mkdir -p ~/.local/opt/fastflowlm
tar xzf fastflowlm_*_linux.tar.gz -C ~/.local/opt/fastflowlm
```

The bundled `flm` wrapper script resolves its own directory via
`BASH_SOURCE`, so **don't symlink the script itself** into `~/.local/bin`
(it'll look for `flm-real` next to the symlink and fail) — use a tiny
launcher instead:

```
cat > ~/.local/bin/flm << 'EOF'
#!/bin/bash
exec "$HOME/.local/opt/fastflowlm/flm" "$@"
EOF
chmod +x ~/.local/bin/flm
```

`flm validate` needs the same memlock limits as `xrt-smi` above (see
"What's in this repo") — it fails with `Memlock limit is too low (8MB)`
in any session that hasn't picked up the `user@.service` override yet
(log out/in or reboot).

## Lemonade Web App + LAN access

The Fedora RPM also installs a web UI launcher (`lemonade-web-app`,
opens `http://localhost:$PORT/lemonade` in a Chromium-based browser via
`xdg-open`/`google-chrome --app=`). It's meant to run on the same machine
as the server, opening a window on the local display.

**If you're on the server only via SSH** (no local desktop session — check
`who`/`loginctl list-sessions` for an active graphical session before
assuming one exists), the launcher can't pop a window. To reach the web
UI from another machine on the LAN instead:

```
lemonade config set host=0.0.0.0
sudo systemctl restart lemond
```

Then open `http://<server-lan-ip>:13305/lemonade` from a browser on any
machine on the LAN. `firewalld`'s default zone already allows
`1025-65535/tcp`, so no firewall change was needed here — check
`firewall-cmd --list-ports` if yours doesn't.

**This exposes the server, unauthenticated, to the whole LAN.** Set
`LEMONADE_API_KEY` (see the comment in `/etc/lemonade/conf.d/`, or
`lemond.service`) if that's not acceptable on your network. To go back to
localhost-only: `lemonade config set host=localhost && sudo systemctl restart lemond`,
and use an SSH tunnel (`ssh -L 13305:localhost:13305 user@host`) instead.

**Gotcha: binding to `0.0.0.0` is not enough on its own.** The web UI
(and any browser-based API call) will fail with `{"error": "Origin not
allowed"}` even once the port is reachable — `lemond` also does its own
Origin-header allowlist check, independent of the network bind. Fix with
an env var drop-in (`config/10-allowed-origins.conf` in this repo, adjust
the origin to your actual LAN IP/port):

```
sudo cp config/10-allowed-origins.conf /etc/lemonade/conf.d/10-allowed-origins.conf
sudo systemctl restart lemond
```

(Replace `<your-lan-ip>` in that file with this host's actual LAN address
before copying it. Note it is a fixed origin, not a pattern — DHCP leases
change, so revisit it if the browser starts getting CORS errors.)

## Confirming a model actually runs on the NPU

There's no NPU utilization shown in `btop`/`htop` (they don't know about
`/dev/accel0`), so "no CPU/GPU load visible" can look like nothing is
happening. Two ways to confirm it's actually the NPU doing the work:

1. `curl http://localhost:13305/api/v1/health` while a model is loaded —
   look for `"recipe": "flm", "device": "npu"` in `all_models_loaded`.
2. Watch CPU usage of the `flm-real` process (`pgrep -f flm-real`) during
   an active generation: it sits around ~10% of one core throughout — far
   too low for a 4B-param model's matmuls to be happening on the CPU, and
   `btop` will simultaneously show no CPU/GPU spike. That ~10% is
   orchestration/IO overhead, not compute; the compute is on the NPU.
