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
#        DS41_INFERENCE_TIMEOUT_S  curl deadline for one inference request (default 900)
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
INFERENCE_TIMEOUT_S=${DS41_INFERENCE_TIMEOUT_S:-900}  # curl deadline for one inference request
CTXS="${1:-32768 131072}"

[ -x "$DS4/ds4-server" ] || { echo "ds4-server not built at $DS4"; exit 2; }
[ -s "$Q2" ] || { echo "Q2 gguf missing: $Q2  (run: $DS4/download_model.sh ds41f-q2)"; exit 2; }

# The LIMIT_GIB verdict rests on the OS-maintained lifetime peak (proc_pid_rusage →
# ri_lifetime_max_phys_footprint): the kernel tracks the process maximum, which polling
# cannot miss. Build a tiny reader once per run; every harness machine has cc (it built
# ds4-server). Falls back to the polled peak_rss when cc is unavailable.
HELPER_DIR=""
RUSAGE_HELPER=""
if command -v cc >/dev/null 2>&1; then
  HELPER_DIR="$(mktemp -d)"
  if ! cc -O2 -o "$HELPER_DIR/pidrusage" -x c - 2>/dev/null <<'EOF'
#include <libproc.h>
#include <sys/resource.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    struct rusage_info_v4 ri;
    if (argc != 2) return 2;
    if (proc_pid_rusage(atoi(argv[1]), RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return 1;
    printf("%llu\n", (unsigned long long)ri.ri_lifetime_max_phys_footprint);
    return 0;
}
EOF
  then
    RUSAGE_HELPER="$HELPER_DIR/pidrusage"
  fi
fi

fail=0
pid="" log="" request="" response=""

# Tear down whatever a run may have left: the server process, this run's temp files, and the
# disk-KV scratch dir. Shared by the EXIT/INT/TERM/HUP traps below; every resource is checked
# before it is touched, so repeat calls and already-reaped/removed state are no-ops. run_one's
# explicit kill/clean paths reassign these same globals as they go, so the trap never resurrects
# old handles (a reaped PID fails kill -0 and is skipped).
cleanup() {
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  [ -n "$log" ] && rm -f "$log"
  [ -n "$request" ] && rm -f "$request"
  [ -n "$response" ] && rm -f "$response"
  [ -n "$KVDISK" ] && rm -rf "$KVDISK"
  [ -n "$HELPER_DIR" ] && rm -rf "$HELPER_DIR"
}
trap 'cleanup; exit 1' INT TERM HUP
trap cleanup EXIT

# Track the server's peak RSS ($pid) across its whole lifetime — startup (model load,
# warm-weights) included, not just the inference window. Callers sample from spawn until the
# process is killed; the peak feeds the LIMIT_GIB evaluation.
sample_rss() {
  rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
  [ -n "$rss" ] && [ "$rss" -gt "$peak_rss" ] 2>/dev/null && peak_rss="$rss"
  return 0
}

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
  peak_rss=0
  sample_rss   # first reading at spawn, so the load/warm-up phase is never missed

  # wait for readiness; ≤900 s (a streaming start may read a lot of the GGUF)
  t=0
  while ! grep -q "listening on http://" "$log" 2>/dev/null; do
    kill -0 "$pid" 2>/dev/null || { echo "ctx=$ctx $label: server exited early:"; tail -4 "$log"; rm -f "$log"; return 1; }
    sample_rss
    sleep 1; t=$((t + 1))
    [ "$t" -gt 900 ] && { echo "ctx=$ctx $label: startup timeout"; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "$log"; return 1; }
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
  # Cross-check ds4's live plan against the Feasibility mirror the app gates on: in streaming
  # mode the resident model must equal ds41NonRoutedBytes within the sampling tolerance.
  # ds41GraphBytes is ctx-dependent (a full Swift formula with its own pinned unit tests), so
  # the harness validates the constant here rather than re-deriving the graph in shell.
  mirror_non_routed_gib="$(awk 'BEGIN{printf "%.2f", 10061367744/1073741824}')"
  if awk "BEGIN{diff=$resident_gib-$mirror_non_routed_gib; if (diff<0) diff=-diff; exit !(diff > $RSS_COMPARISON_TOLERANCE_MIB/1024)}"; then
    echo "ctx=$ctx $label: resident model ${resident_gib} GiB differs from the ds41NonRoutedBytes mirror (${mirror_non_routed_gib} GiB) by more than ${RSS_COMPARISON_TOLERANCE_MIB} MiB"
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

  curl -fsS --max-time "$INFERENCE_TIMEOUT_S" "http://127.0.0.1:$PORT/v1/chat/completions" \
    -H 'Content-Type: application/json' -H 'Expect:' --data-binary "@$request" >"$response" 2>>"$log" &
  cpid=$!
  n=0
  while kill -0 "$cpid" 2>/dev/null || [ "$n" -lt 6 ]; do   # at least ~3 s of samples
    sample_rss
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
  # Kernel-accounted lifetime peak, read BEFORE the process dies: the authoritative value
  # for the LIMIT_GIB verdict. The polled peak_rss stays as the fallback (and is still
  # sampled across startup for the live row) when the helper could not be built.
  footprint_bytes=""
  if [ -n "$RUSAGE_HELPER" ]; then
    footprint_bytes="$("$RUSAGE_HELPER" "$pid" 2>/dev/null)"
    [ -n "$footprint_bytes" ] && [ "$footprint_bytes" -gt 0 ] 2>/dev/null || footprint_bytes=""
  fi
  rm -f "$request" "$response"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  rm -f "$log"; sleep 2   # free the port

  if [ -n "$footprint_bytes" ]; then
    total_raw="$(awk "BEGIN{printf \"%.9f\", $footprint_bytes/1073741824}")"
  else
    total_raw="$(awk "BEGIN{printf \"%.9f\", $peak_rss/1024/1024}")"
  fi
  rss_gib="$(awk "BEGIN{printf \"%.1f\", $total_raw}")"
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
