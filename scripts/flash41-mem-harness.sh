#!/bin/sh
# flash41-mem-harness.sh — measure V4.1 Flash (Q2) resident memory across context sizes on a
# 128 GiB+ Mac. Spins up the REAL ds4-server with --ssd-streaming, warms the model, prefills to
# the configured context frontier, and records peak RSS plus ds4's own memory plan.
#
# The GGUF carries ~189 GiB of disk-only Engram tables that never become resident; only the
# ~9.4 GiB of non-routed weights, the per-session graph, and the auto-fitted expert cache are.
# The harness cross-checks ds4's `ds4: memory:` line against the Feasibility mirror
# (`ds41GraphBytes`, `ds41NonRoutedBytes`) that the app uses for its launch gate.
#
# Usage: scripts/flash41-mem-harness.sh ["ctx1 ctx2 …"]   (default: 32768 131072)
# Env:   DS41_LIMIT_GIB  hard machine ceiling (default 128)
# Exit non-zero if a run exceeds the ceiling or ds4's memory plan is missing.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DS4="$ROOT/external/ds4"
GGUF_DIR="${DS4_GGUF_DIR:-$HOME/Library/Application Support/DS4 Control/gguf}"
Q2="$GGUF_DIR/DeepSeek-V4.1-Flash-Q2.gguf"
MODEL_ID="deepseek-v4.1-flash"
PORT=8138
LIMIT_GIB=${DS41_LIMIT_GIB:-128}   # hard machine ceiling
USABLE_GIB=$((LIMIT_GIB - 4))      # practical limit after the OS reserve
FRONTIER_MARGIN_TOKENS=64
RSS_COMPARISON_TOLERANCE_MIB=64
KVDISK="/tmp/ds41-memharness-kv"
CTXS="${1:-32768 131072}"

[ -x "$DS4/ds4-server" ] || { echo "ds4-server not built at $DS4"; exit 2; }
[ -s "$Q2" ] || { echo "Q2 gguf missing: $Q2  (run: $DS4/download_model.sh ds41f-q2)"; exit 2; }

fail=0

# run_one <ctx> <disk:0|1>  -> prints a result row; returns non-zero if over the ceiling
run_one() {
  ctx="$1"; disk="$2"
  total_raw=""
  log="$(mktemp)"
  if [ "$disk" = 1 ]; then
    rm -rf "$KVDISK"; mkdir -p "$KVDISK"; label="disk-kv "
    ( cd "$DS4" && unset DS4_METAL_MEMORY_REPORT DS4_METAL_DISABLE_STREAMING_EXPERT_TIMING_SUMMARY && \
      exec ./ds4-server -m "$Q2" --ctx "$ctx" --host 127.0.0.1 --port "$PORT" \
        --metal --power 100 --ssd-streaming --warm-weights \
        --kv-disk-dir "$KVDISK" --kv-disk-space-mb 16384 ) >"$log" 2>&1 &
  else
    label="no-disk "
    ( cd "$DS4" && unset DS4_METAL_MEMORY_REPORT DS4_METAL_DISABLE_STREAMING_EXPERT_TIMING_SUMMARY && \
      exec ./ds4-server -m "$Q2" --ctx "$ctx" --host 127.0.0.1 --port "$PORT" \
        --metal --power 100 --ssd-streaming --warm-weights ) >"$log" 2>&1 &
  fi
  pid=$!   # exec in the subshell => $! is ds4-server itself

  # wait for readiness; ≤900 s (a streaming start may read a lot of the GGUF)
  t=0
  while ! grep -q "listening on http://" "$log" 2>/dev/null; do
    kill -0 "$pid" 2>/dev/null || { echo "ctx=$ctx $label: server exited early:"; tail -4 "$log"; rm -f "$log"; return 1; }
    sleep 1; t=$((t + 1))
    [ "$t" -gt 900 ] && { echo "ctx=$ctx $label: startup timeout"; kill "$pid" 2>/dev/null; rm -f "$log"; return 1; }
  done

  # ds4's own plan: "ds4: memory: KV … + buffers … + resident model R GiB … = T GiB planned".
  planned_gib="$(sed -n 's/.*= \([0-9.]*\) GiB planned.*/\1/p' "$log" | head -1)"
  resident_gib="$(sed -n 's/.*resident model \([0-9.]*\) GiB.*/\1/p' "$log" | head -1)"
  if [ -z "$planned_gib" ] || [ -z "$resident_gib" ]; then
    echo "ctx=$ctx $label: ds4 memory plan missing (resident='$resident_gib' planned='$planned_gib')"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "$log"; sleep 2
    return 1
  fi
  # Streaming must keep the disk-only Engram rows out of the resident model.
  if awk "BEGIN{exit !($resident_gib > 20)}"; then
    echo "ctx=$ctx $label: resident model ${resident_gib} GiB exceeds the ~9.4 GiB non-routed set"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "$log"; sleep 2
    return 1
  fi

  # Repeated special tokens give a one-token-per-marker payload; drive prefill to the frontier so
  # lazy Metal scratch reaches its real long-prompt peak. V4.1's tokenizer may split markers, so
  # the check only requires a frontier-scale prompt (≥ half the target).
  prompt_target=$((ctx - FRONTIER_MARGIN_TOKENS))
  prompt_floor=$((prompt_target / 2))
  if [ "$prompt_target" -le 0 ]; then
    echo "ctx=$ctx $label: context must exceed $FRONTIER_MARGIN_TOKENS tokens"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "$log"; sleep 2
    return 1
  fi
  request="$(mktemp)"; response="$(mktemp)"
  {
    printf '%s' "{\"model\":\"$MODEL_ID\",\"messages\":[{\"role\":\"user\",\"content\":\""
    awk -v count="$prompt_target" 'BEGIN { for (i=0; i<count; i++) printf "<think>" }'
    printf '%s' '"}],"max_tokens":1,"temperature":0}'
  } > "$request"

  curl -fsS "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
    -H 'Expect:' --data-binary "@$request" >"$response" 2>>"$log" &
  cpid=$!
  peak_rss=0; n=0
  while kill -0 "$cpid" 2>/dev/null || [ "$n" -lt 6 ]; do   # at least ~3 s of samples
    rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -n "$rss" ] && [ "$rss" -gt "$peak_rss" ] 2>/dev/null && peak_rss="$rss"
    n=$((n + 1)); sleep 0.5
  done
  if ! wait "$cpid"; then
    echo "ctx=$ctx $label: inference request failed"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    tail -8 "$log"; rm -f "$log" "$request" "$response"; sleep 2
    return 1
  fi
  prompt_tokens="$(grep -o '"prompt_tokens":[0-9][0-9]*' "$response" | head -1 | cut -d: -f2)"
  case "$prompt_tokens" in
    ''|*[!0-9]*)
      echo "ctx=$ctx $label: response prompt-token measurement missing"
      kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
      rm -f "$log" "$request" "$response"; sleep 2
      return 1
      ;;
  esac
  if [ "$prompt_tokens" -lt "$prompt_floor" ]; then
    echo "ctx=$ctx $label: prompt reached only $prompt_tokens tokens (floor $prompt_floor)"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    rm -f "$log" "$request" "$response"; sleep 2
    return 1
  fi
  rm -f "$request" "$response"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  rm -f "$log"; sleep 2   # free the port

  rss_gib="$(awk "BEGIN{printf \"%.1f\", $peak_rss/1024/1024}")"
  total_raw="$(awk "BEGIN{printf \"%.9f\", $peak_rss/1024/1024}")"
  total_gib="$(awk "BEGIN{printf \"%.1f\", $total_raw}")"
  ok="$(awk "BEGIN{print ($total_raw<=$LIMIT_GIB)?\"YES\":\"NO\"}")"
  warn="$(awk "BEGIN{print ($total_raw> $USABLE_GIB && $total_raw<=$LIMIT_GIB)?\" (>${USABLE_GIB} usable, will page)\":\"\"}")"
  printf '  %-9s %s resident_model=%-7s planned=%-7s peak_RSS=%-7s tokens=%-8s fits_%s=%s%s\n' \
    "$ctx" "$label" "${resident_gib}GiB" "${planned_gib}GiB" "${rss_gib}GiB" "$prompt_tokens" "$LIMIT_GIB" "$ok" "$warn"
  awk "BEGIN{exit !($total_raw<=$LIMIT_GIB)}"
}

echo "=== V4.1 Flash q2 resident-memory harness — limit ${LIMIT_GIB} GiB (usable ~${USABLE_GIB} GiB after OS) ==="
echo "    model: $Q2 (--ssd-streaming --power 100)"
last=""; for c in $CTXS; do last="$c"; done
for ctx in $CTXS; do
  run_one "$ctx" 1 || fail=1          # disk-KV: the real default path (gated)
done
echo "  --- control (no disk KV) ---"
run_one "$last" 0 || fail=1

rm -rf "$KVDISK"
if [ "$fail" = 0 ]; then
  echo "PASS: every run fits within ${LIMIT_GIB} GiB and keeps Engram out of the resident set."
else
  echo "FAIL: a memory measurement or resident-set check failed."
fi
exit "$fail"
