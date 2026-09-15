# What 18 local models actually do on a Strix Halo box

A rough orientation table for the AMD Ryzen AI Max+ 395 (128 GB unified memory,
Radeon 8060S iGPU + XDNA2 NPU), measured 2026-09-15 on Nobara Linux 44,
kernel 7.2.0-202.

**This is a small, subjective smoke test, not a benchmark suite.** Six tasks,
each with a machine-checkable answer. It is enough to tell "this model is
usable on this box" from "this one is not", and nothing more. Read the caveats
at the bottom before drawing conclusions from the point totals — one of the six
tasks does most of the separating, and it is a task language models are known
to be bad at for reasons unrelated to capability.

What the table is genuinely good for: **throughput on this hardware**, which
varies by a factor of 8 and is not predictable from the parameter count in the
model's name.

## The table

### What the models are

| Model | Runs on | Engine | File GB | RAM in use GB | Quant | Context | Can |
|---|---|---|---|---|---|---|---|
| `qwen3-vl:30b` | iGPU | Ollama | 19.6 | 45 | Q4_K_M | 256k | vision, tools, thinking |
| `Gemma-4-E4B-it-GGUF` | iGPU | Lemonade | 5.6 | ? | Q4_K_M | 128k | vision, tools |
| `qwen3.6:latest` | iGPU | Ollama | 23.9 | 28 | Q4_K_M | 256k | vision, tools, thinking |
| `qwen3.6-en:latest` | iGPU | Ollama | 23.9 | 23 | Q4_K_M | 256k | vision, tools, thinking |
| `gpt-oss-120b` | iGPU | Lemonade | 59.0 | ? | MXFP4 | 128k | tools |
| `qwen3.8:latest` | iGPU | Ollama | 17.7 | 19 | Q4_K_M | 256k | vision, tools, thinking |
| `muse-glimmer:latest` | iGPU | Ollama | 18.2 | 17 | Q4_K_M | 128k | vision, tools, thinking |
| `gemma4:31b` | iGPU | Ollama | 19.9 | 22 | Q4_K_M | 256k | vision, tools, thinking |
| `gemma4:e2b` | iGPU | Ollama | 7.2 | 2 | Q4_K_M | 128k | vision, tools, thinking |
| `DeepSeek-Qwen3-8B-GGUF` | iGPU | Lemonade | 4.9 | ? | Q4_1 | 128k | tools, thinking |
| `qwen3-vl:8b-instruct` | iGPU | Ollama | 6.1 | 44 | Q4_K_M | 256k | vision, tools |
| `qwen3.5:9b` | iGPU | Ollama | 6.6 | 14 | Q4_K_M | 256k | vision, tools, thinking |
| `gemma4:12b` | iGPU | Ollama | 7.6 | 9 | Q4_K_M | 256k | vision, tools, thinking |
| `gemma4:26b-a4b-it-bf16` | iGPU | Ollama | 51.7 | 52 | F16 | 256k | vision, tools, thinking |
| `qwen3.6-moe-35b-a3b-FLM` | NPU | Lemonade | ? | ? | 35b-a3b | 256k | vision, tools, thinking |
| `NousResearch_Hermes-4-1...` | iGPU | Ollama | 9.0 | 16 | Q4_K_M | 40k | tools, thinking |
| `gpt-oss-20b-FLM` | NPU | Lemonade | ? | ? | 20b | 128k | thinking |
| `gemma4-it-e4b-FLM` | NPU | Lemonade | ? | ? | e4b | 128k | vision, tools, thinking |

### How they did

| Model | Score | logic | time | json | instruct | translate | tool | tok/s warm | load s |
|---|---|---|---|---|---|---|---|---|---|
| `qwen3-vl:30b` | **6/6** | ok | ok | ok | ok | ok | ok | **64.5** | 7 |
| `Gemma-4-E4B-it-GGUF` | **6/6** | ok | ok | ok | ok | ok | ok | **56.8** | 3 |
| `qwen3.6:latest` | **6/6** | ok | ok | ok | ok | ok | ok | **54.5** | 7 |
| `qwen3.6-en:latest` | **6/6** | ok | ok | ok | ok | ok | ok | **54.0** | 7 |
| `gpt-oss-120b` | **6/6** | ok | ok | ok | ok | ok | ok | **49.3** | 15 |
| `qwen3.8:latest` | **6/6** | ok | ok | ok | ok | ok | ok | **18.2** | 9 |
| `muse-glimmer:latest` | **6/6** | ok | ok | ok | ok | ok | ok | **11.6** | 11 |
| `gemma4:31b` | **6/6** | ok | ok | ok | ok | ok | ok | **9.7** | 13 |
| `gemma4:e2b` | **5/6** | ok | ok | ok | -- | ok | ok | **82.0** | 5 |
| `DeepSeek-Qwen3-8B-GGUF` | **5/6** | ok | ok | ok | -- | ok | ok | **40.6** | 6 |
| `qwen3-vl:8b-instruct` | **5/6** | ok | ok | ok | -- | ok | ok | **37.3** | 5 |
| `qwen3.5:9b` | **5/6** | ok | ok | ok | ab | ok | ok | **31.5** | 5 |
| `gemma4:12b` | **5/6** | ok | ok | ok | ab | ok | ok | **23.3** | 6 |
| `gemma4:26b-a4b-it-bf16` | **5/6** | ok | ok | ok | ab | ok | ok | **21.1** | 15 |
| `qwen3.6-moe-35b-a3b-FLM` | **5/6** | -- | ok | ok | ok | ok | ok | **10.2** | 17 |
| `NousResearch_Hermes-4-1...` | **4/6** | ok | ok | ab | -- | ok | ok | **22.5** | 6 |
| `gpt-oss-20b-FLM` | **4/6** | ok | ok | ok | -- | ok | -- | **16.2** | 16 |
| `gemma4-it-e4b-FLM` | **4/6** | -- | ok | ok | -- | ok | ok | **10.1** | 9 |

## What the numbers say

### Architecture beats size, by a lot

`gpt-oss-120b` is three times the parameters of `gemma4:31b` and **five times
faster** (49.3 vs 9.7 tok/s). `qwen3-vl:30b` is the same size class as
`gemma4:31b` and **6.6x faster**.

The pattern is consistent: every model above 40 tok/s is a mixture-of-experts,
every model below 25 tok/s is dense or unquantized. On unified memory the
bottleneck is bandwidth, not compute — what matters is how many bytes have to
be read per token, not how many parameters exist.

Corollary: the parameter count in the model name is a poor guide here. A 120B
MoE in MXFP4 is comfortable; a 31B dense model in Q4 is sluggish.

### Quantization is part of the same story

`gemma4:26b-a4b-it-bf16` is the only unquantized model in the set (F16, 51.7 GB)
and runs at 21.1 tok/s. Its quantized siblings in the same family are two to
four times faster. Four bytes per weight instead of one is four times the
traffic over the same bus.

### The NPU is slower than the iGPU — measurably, on identical weights

The same Gemma 4 E4B, once through llama.cpp on the iGPU and once through
FastFlowLM on the NPU:

| | Points | tok/s |
|---|---|---|
| Gemma 4 E4B on the **iGPU** | **6/6** | **56.8** |
| Gemma 4 E4B on the **NPU** | 4/6 | 10.1 |

**5.6x slower**, and it also loses two of the six tasks the same file passes on
the iGPU. Measured twice, hours apart, same result both times.

The per-task timings point at a mechanism rather than a quality gap:

| Task | iGPU | NPU |
|---|---|---|
| logic puzzle | passed after **10.5 s** | failed after **1.8 s** |
| time / json / translate / tool call | passed | passed |

On the iGPU the model spends ten seconds on the reasoning problem and gets it
right. The same file on the NPU answers in under two seconds and gets it wrong
— not because the NPU is fast (it is five times slower) but because it emits far
less text. Everything that is pure transformation still works. This is
consistent with the reasoning phase being absent or cut short on the
FastFlowLM path, but we have not proven that; the second failed task
(`instruct`) does not fit that explanation, so treat it as an open question
rather than a finding.

**None of this makes the NPU useless.** It is a second compute unit that runs
*while the iGPU is busy* — which on this box is the whole point, because
ComfyUI and the language models otherwise fight over the same silicon.

### Nothing fell back to the CPU

Placement was measured, not assumed: for Ollama via `/api/ps` (`size_vram` vs
`size`), for Lemonade via the `device` field. All 18 models sat entirely on
iGPU or NPU. So the throughput spread above is architecture and quantization,
not a hidden CPU spill.

### RAM in use is not the file size

`qwen3-vl:8b-instruct` is a 6.1 GB file that occupies **44 GB** once loaded,
because the KV cache for a 262k context window dwarfs the weights. If you are
planning what fits alongside what, the "RAM GB" column is the one to use.

## The six tasks

Each has a mechanically checkable answer — no judgement calls:

| Task | Checked against |
|---|---|
| `logic` | age puzzle, answer must be 12 |
| `time` | arrival time, must be 17:25 |
| `json` | valid JSON with exactly three given keys |
| `instruct` | "describe a sunset in exactly seven words" — words counted |
| `translate` | must be English and contain "Tuesday" |
| `tool` | does a real function call come back? |

Prompts are German, because that is what this machine is used in.

## Caveats — read these before using the point totals

1. **The ranking is dominated by one task.** Eight of eighteen models score 6/6,
   so the test does not discriminate at the top at all. Almost every failure
   below that is `instruct` — counting words. Models see tokens, not words;
   this is a known weakness with little bearing on whether a model is useful.
   The failures are all near misses (6 or 8 words instead of 7).
2. **`ab` means unjudged, not failed.** Four models hit the 2500-token ceiling
   while reasoning and never reached an answer. That is a limit of the harness.
3. **One anomaly.** `gpt-oss-20b-FLM` returned an empty response with no finish
   reason on `instruct`. Counted as a failure for lack of anything better, but
   it is not a clean one.
4. **Single run per model.** Speed figures were spot-checked for
   reproducibility — `gpt-oss-120b` measured 49.0 / 48.2 / 49.3 across three
   separate runs, Gemma 4 on the iGPU 56.7 / 57.0 / 56.8 — but the task results
   are one run each.
5. **Nothing else may run during measurement.** An image generation in parallel
   halved Gemma's throughput (56.8 → 24.7 tok/s) and *the number looked
   entirely plausible*. It was caught only because it disagreed with an earlier
   measurement. The harness now refuses to start when ComfyUI or an image
   request is active.
6. **Watch the memory.** Neither engine frees a model when you switch away from
   it. Measuring in a loop drove this box to 0 GB available and 17 GB of swap,
   silently, mid-run. The harness now unloads both engines between models and
   skips a model that would not fit.

## Reproducing

The scripts are not in this repo yet; they are three small Python files that
talk to Lemonade on `:13311` and Ollama on `:11434` over their OpenAI-compatible
endpoints. Open an issue if you want them and I will clean them up and add them.

## Hardware

- AMD Ryzen AI Max+ 395 "Strix Halo", 16C/32T Zen5
- Radeon 8060S iGPU (gfx1151) + XDNA2 NPU
- 128 GB unified memory — no separate VRAM, see the NPU notes in the main README
- Nobara Linux 44, kernel 7.2.0-202
- Engines: Lemonade (llama.cpp on the iGPU, FastFlowLM on the NPU), Ollama (ROCm)
