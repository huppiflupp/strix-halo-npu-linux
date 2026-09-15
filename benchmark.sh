#!/bin/bash
# Lean, re-runnable speed+correctness snapshot across NPU/iGPU backends and
# Hermes tool-calling. Not a research tool — same 2 prompts on every LLM
# backend, one tool-use check via Hermes. Whole run: ~3-5 min.
#
# Usage: ./benchmark.sh
# Requires: lemond running (localhost:13305), ollama running (localhost:11434),
# hermes CLI configured with the "lemonade-npu" provider (see README.md).
set -uo pipefail

# German locale makes printf/bc choke on "." decimals (expects ","); force C.
export LC_ALL=C

LEMONADE_URL="http://127.0.0.1:13305/api/v1/chat/completions"
OLLAMA_URL="http://127.0.0.1:11434/api/chat"
HERMES="$HOME/.local/bin/hermes"

# task 1: deterministic word problem, single correct numeric answer.
TASK1_PROMPT="Ein Zug fährt 120km in 2 Stunden, dann 180km in 3 Stunden. Wie hoch ist die Durchschnittsgeschwindigkeit für die gesamte Strecke in km/h? Antworte nur mit der Zahl."
TASK1_EXPECT="60"

# task 2: representative daily-use prompt, no strict correctness check —
# speed/wall-time signal only, with a basic non-empty/non-garbage sanity check.
TASK2_PROMPT="Erkläre in 3 Sätzen, was eine NPU ist."

# Hermes tool-use ground truth: run the same command Hermes is asked to run,
# so the check is against this machine's actual values, not hardcoded ones.
TOOL_PROMPT="Führe im Terminal 'hostname && id -u' aus und gib mir exakt die Ausgabe zurück."
REAL_HOSTNAME="$(hostname)"
REAL_UID="$(id -u)"

RESULTS_FILE="$(mktemp)"
trap 'rm -f "$RESULTS_FILE"' EXIT

# --- Lemonade (OpenAI-compatible) chat completion ---
# $1=model $2=prompt $3=max_tokens $4=timeout_s -> prints "decode_tps|prefill_tps|content|wall_s"
lemonade_call() {
    local model="$1" prompt="$2" max_tokens="$3" timeout_s="$4"
    local start end wall resp
    start=$(date +%s.%N)
    resp=$(curl -s -m "$timeout_s" "$LEMONADE_URL" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg m "$model" --arg p "$prompt" --argjson mt "$max_tokens" \
            '{model:$m, messages:[{role:"user",content:$p}], max_tokens:$mt}')")
    end=$(date +%s.%N)
    wall=$(echo "$end - $start" | bc)
    if [ -z "$resp" ]; then echo "0|0|ERROR:empty-response|$wall"; return; fi
    local decode prefill content
    # flm backend reports speed under usage.*; llamacpp backend reports the
    # same numbers under timings.predicted_per_second/prompt_per_second.
    decode=$(echo "$resp" | jq -r '.usage.decoding_speed_tps // .timings.predicted_per_second // 0' 2>/dev/null)
    prefill=$(echo "$resp" | jq -r '.usage.prefill_speed_tps // .timings.prompt_per_second // 0' 2>/dev/null)
    # reasoning models can leave content empty and put the answer in
    # reasoning_content if max_tokens is spent thinking; concatenate both so
    # the correctness grep still sees an in-progress final answer if present.
    # gsub newlines/pipes to spaces: content flows through a "|"-delimited,
    # one-line-per-call protocol below — an embedded "\n" or "|" from a
    # multi-paragraph reasoning trace desyncs every cut -f call downstream.
    content=$(echo "$resp" | jq -r '((.choices[0].message.content // "") + " " + (.choices[0].message.reasoning_content // "")) | gsub("[\n|]"; " ")' 2>/dev/null)
    [ -z "${content// /}" ] && content="ERROR:no-content"
    echo "${decode:-0}|${prefill:-0}|${content:-ERROR}|$wall"
}

# --- Ollama (native format) chat completion ---
ollama_call() {
    local model="$1" prompt="$2" max_tokens="$3" timeout_s="$4"
    local start end wall resp
    start=$(date +%s.%N)
    resp=$(curl -s -m "$timeout_s" "$OLLAMA_URL" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg m "$model" --arg p "$prompt" --argjson mt "$max_tokens" \
            '{model:$m, messages:[{role:"user",content:$p}], stream:false, options:{num_predict:$mt}}')")
    end=$(date +%s.%N)
    wall=$(echo "$end - $start" | bc)
    if [ -z "$resp" ]; then echo "0|0|ERROR:empty-response|$wall"; return; fi
    local decode prefill content ec ed pc pd
    ec=$(echo "$resp" | jq -r '.eval_count // 0')
    ed=$(echo "$resp" | jq -r '.eval_duration // 0')
    pc=$(echo "$resp" | jq -r '.prompt_eval_count // 0')
    pd=$(echo "$resp" | jq -r '.prompt_eval_duration // 0')
    decode=$( [ "${ed:-0}" != "0" ] && echo "scale=1; $ec / ($ed/1000000000)" | bc || echo 0 )
    prefill=$( [ "${pd:-0}" != "0" ] && echo "scale=1; $pc / ($pd/1000000000)" | bc || echo 0 )
    # same reasoning-model gotcha as lemonade_call: content can be empty
    # with the answer sitting in the separate "thinking" field instead.
    content=$(echo "$resp" | jq -r '((.message.content // "") + " " + (.message.thinking // "")) | gsub("[\n|]"; " ")')
    [ -z "${content// /}" ] && content="ERROR:no-content"
    echo "${decode:-0}|${prefill:-0}|${content:-ERROR}|$wall"
}

# label|call_fn|model|timeout_s. Lemonade only keeps one LLM slot loaded
# (max_loaded_models.llm=1), so switching model/backend evicts the previous
# one and reloads — give every Lemonade entry room for that, and qwen3.6-moe
# extra: first call on a cold slot has to load ~30GB of weights.
BACKENDS=(
    "gemma4-it-e4b-FLM (NPU)|lemonade|gemma4-it-e4b-FLM|90"
    "gpt-oss-20b-FLM (NPU)|lemonade|gpt-oss-20b-FLM|90"
    "qwen3.6-moe-35b-a3b-FLM (NPU)|lemonade|qwen3.6-moe-35b-a3b-FLM|150"
    "Gemma-4-E4B-it-GGUF (iGPU)|lemonade|Gemma-4-E4B-it-GGUF|90"
    "qwen3.8:latest (iGPU/Ollama)|ollama|qwen3.8:latest|60"
)

echo "Running benchmark — same 2 prompts across ${#BACKENDS[@]} backends, then 2 Hermes tool-use checks..." >&2
echo "" >&2

{
echo "| Model | Task1 decode | Task1 correct | Task2 decode | Task2 prefill | Total wall (both tasks) |"
echo "|---|---|---|---|---|---|"
} > "$RESULTS_FILE"

for entry in "${BACKENDS[@]}"; do
    IFS='|' read -r label engine model timeout_s <<< "$entry"
    echo "-> $label" >&2

    # task1 gets 200 tokens, not a tight 60 — reasoning models (qwen3.8,
    # gpt-oss, qwen3.6-moe) spend a chunk of budget thinking before the
    # final answer, and a too-tight cap fails them on truncation, not on
    # actually getting the math wrong.
    if [ "$engine" = "lemonade" ]; then
        t1=$(lemonade_call "$model" "$TASK1_PROMPT" 200 "$timeout_s")
        t2=$(lemonade_call "$model" "$TASK2_PROMPT" 250 "$timeout_s")
    else
        t1=$(ollama_call "$model" "$TASK1_PROMPT" 200 "$timeout_s")
        t2=$(ollama_call "$model" "$TASK2_PROMPT" 250 "$timeout_s")
    fi

    t1_decode=$(echo "$t1" | cut -d'|' -f1)
    t1_content=$(echo "$t1" | cut -d'|' -f3)
    t1_wall=$(echo "$t1" | cut -d'|' -f4)
    t2_decode=$(echo "$t2" | cut -d'|' -f1)
    t2_prefill=$(echo "$t2" | cut -d'|' -f2)
    t2_wall=$(echo "$t2" | cut -d'|' -f4)

    if echo "$t1_content" | grep -q "$TASK1_EXPECT"; then
        correct="✓"
    else
        correct="✗"
    fi
    total_wall=$(echo "$t1_wall + $t2_wall" | bc)

    printf "| %s | %.1f tok/s | %s | %.1f tok/s | %.1f tok/s | %.1fs |\n" \
        "$label" "$t1_decode" "$correct" "$t2_decode" "$t2_prefill" "$total_wall" >> "$RESULTS_FILE"
done

echo "" >&2
echo "-> Hermes tool-use: gemma4-it-e4b-FLM" >&2
hermes_gemma4=$(timeout 60 "$HERMES" --provider lemonade-npu -m gemma4-it-e4b-FLM -z "$TOOL_PROMPT" 2>&1)
echo "-> Hermes tool-use: gpt-oss-20b-FLM" >&2
hermes_gptoss=$(timeout 60 "$HERMES" --provider lemonade-npu -m gpt-oss-20b-FLM -z "$TOOL_PROMPT" 2>&1)

check_tool_result() {
    local resp="$1"
    if echo "$resp" | grep -q "$REAL_HOSTNAME" && echo "$resp" | grep -q "$REAL_UID"; then
        echo "✓ real output returned"
    else
        echo "✗ did not return real output (fabricated or refused)"
    fi
}

{
echo ""
echo "### Hermes tool-use (\`hostname && id -u\`, ground truth: $REAL_HOSTNAME / $REAL_UID)"
echo ""
echo "| Model | Result |"
echo "|---|---|"
echo "| gemma4-it-e4b-FLM | $(check_tool_result "$hermes_gemma4") |"
echo "| gpt-oss-20b-FLM | $(check_tool_result "$hermes_gptoss") |"
} >> "$RESULTS_FILE"

cat "$RESULTS_FILE"
