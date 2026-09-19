# Building AMD's HRX llama.cpp backend on Fedora/Nobara (Strix Halo)

HRX is AMD's new lightweight ROCm runtime with a native llama.cpp backend, proposed in
[llama.cpp PR #27218](https://github.com/ggml-org/llama.cpp/pull/27218) and RFC discussion
[#27219](https://github.com/ggml-org/llama.cpp/discussions/27219). It targets RDNA3 and
RDNA3.5 (Strix Halo). As of this writing, it only supports one model, Qwen3-30B-A3B-Instruct-2507 in Q4_K_M.

The upstream build instructions assume a ROCm tree under `/opt/rocm`. On Fedora 44 /
Nobara 44 (ROCm 7.1 from distro packages, kernel 7.2) that path fails in three places.
This is the recipe that works on this machine (2026-09-19). Everything stays out of the system ROCm.

## TL;DR

```bash
mkdir -p ~/src/hrx && cd ~/src/hrx
git clone --depth 1 --branch users/stella/hrx-rfc-v1 https://github.com/AMD-Ecosystem/llama.cpp
git clone https://github.com/ROCm/hrx-system
git -C hrx-system checkout 8ef82dbfa0385f7953ceadd884317be7e512ea38   # pin from the RFC thread

# 1) Build with ROCm's clang, but do NOT pass -DIREE_ROCM_PATH (see below)
CLANG=/usr/lib64/rocm/llvm/bin/clang
cmake -G Ninja -B build -S llama.cpp -DGGML_HRX=ON -DHRX_SOURCE_DIR=$PWD/hrx-system \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=$CLANG -DCMAKE_CXX_COMPILER=${CLANG}++
cmake --build build --target llama-cli llama-bench llama-perplexity      # ~80 s on a 395

# 2) A newer HSA runtime, only for HRX: TheRock ROCm 10.1 in a venv
python3 -m venv ~/.venvs/therock10
~/.venvs/therock10/bin/pip install --index-url https://rocm.nightlies.amd.com/whl-multi-arch/ \
  "rocm-sdk-core==10.1.0a20260822"
export THEROCK=$(echo ~/.venvs/therock10/lib/python3*/site-packages/_rocm_sdk_core/lib)

# 3) Run
LD_LIBRARY_PATH=$THEROCK ./build/bin/llama-cli --list-devices
#   HRX0: AMD Radeon 8060S Graphics (Node 1) (gfx1151) (122880 MiB, 122880 MiB free)
```

## The three pitfalls

| Symptom | Cause | Fix |
|---|---|---|
| `AQL profile SDK headers were not found. Expected to find aqlprofile-sdk/aql_profile_v2.h` while building the HRX sub-project | Fedora's ROCm 7.1 has only the older `hsa/hsa_ven_amd_aqlprofile.h`. Passing `-DIREE_ROCM_PATH` puts HRX in `package` mode, where it insists on system headers. | Leave `IREE_ROCM_PATH` unset; HRX then fetches its pinned ROCm headers itself. (Installing `aqlprofile-devel` may also work; not tried.) |
| `Assertion '__n < this->size()' failed` in `rocr::core::Signal::WaitMultiple` ← `hsa_amd_signal_wait_any`, at startup | Fedora's `libhsa-runtime64` (ROCm 7.1, HSA 1.18) is built with `_GLIBCXX_ASSERTIONS` and indexes past a vector on HRX's call pattern | A newer HSA runtime (1.21) via `LD_LIBRARY_PATH`, only for HRX |
| Segfault in `rocr::AMD::GpuAgent::InitDma` inside `hsa_init`; TheRock's own `rocminfo` crashes too | TheRock 7.14 (the newest in the default `v2/gfx1151` pip index, June 2026) doesn't work with kernel 7.2 here | Use the `whl-multi-arch` index, which carries ROCm 10.1 (HSA 1.21): `rocminfo` and HRX both work |

Notes:
- Only HRX needs the TheRock runtime. Vulkan and HIP builds keep using the distro ROCm, and
  nothing is installed system-wide.
- The CMake step warns `OpenMP not found` with ROCm's clang. That only affects the CPU backend and doesn't matter for GPU runs.
- The model must be Q4_K_M:
  `unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF` → `Qwen3-30B-A3B-Instruct-2507-Q4_K_M.gguf`.

## Tested on

GMKtec EVO-X2, Ryzen AI Max+ 395, 128 GB, Nobara 44, kernel `7.2.0-202.nobara.fc44`,
Mesa 26.2.1, distro ROCm 7.1.1. Full profile: [HARDWARE.md](HARDWARE.md).

## Results (2026-09-19)

Qwen3-30B-A3B-Instruct-2507 Q4_K_M, `-fa 1`; Vulkan/HIP from llama.cpp master `ec92815`.
Posted to [#27219](https://github.com/ggml-org/llama.cpp/discussions/27219#discussioncomment-18512703).

| | HRX | Vulkan | HIP |
|---|---|---|---|
| pp512 | **1724** | 1466 | 1650 |
| pp1024 / pp2048 (single ubatch, `-ub` = prompt) | 1836 / 1653 | – | – |
| pp4096 (default `-ub 512`) | fails | 1187 | 1429 |
| tg128 | 85.3 | **89.5** | 72.9 |
| tg128 after 8k context | fails | 65.4 | 55.9 |
| perplexity (wikitext-2, 20 chunks) | fails | 6.4075 | 6.4061 |

- HRX is correct: greedy output over 96 tokens is identical to Vulkan/HIP on 2 of 3 prompts; the third
  diverges where HIP also does (normal floating-point ordering).
- Short prompts are fastest on HRX (+18 % vs Vulkan, +4 % vs HIP); for generation Vulkan still wins.
- In this RFC snapshot only the first ubatch works: anything that attends to an existing KV cache
  (second ubatch, `-d`, multi-turn chat) fails with `res = -3`. `llama-perplexity` fails on a
  `GET_ROWS` with an empty index tensor. Not usable for multi-turn chat yet.
