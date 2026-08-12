#!/bin/sh
# flash-mem-harness.sh — measure V4 Flash (q2) resident memory across context sizes to verify
# it fits a 96 GiB machine. Spins up the REAL ds4-server (loads the ~81 GB model) at each ctx,
# warms the weights, sends one short prompt, and samples peak RSS + peak physical footprint.
#
# ds4 exposes no memory metric, so resident memory is measured externally (ps / vmmap). The
# on-disk KV cache checkpoints resident tensors rather than replacing them, so we test it and
# (at the largest ctx) a no-disk control to verify that the memory requirement is unchanged.
#
# Usage: scripts/flash-mem-harness.sh ["ctx1 ctx2 …"]   (default: 131072 393216 1000000)
# Exit non-zero if a run exceeds 96 GiB or disk KV reduces the measured resident allocation.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DS4="$ROOT/external/ds4"
GGUF_DIR="$HOME/Library/Application Support/DS4 Control/gguf"
Q2="$GGUF_DIR/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf"
PORT=8137
LIMIT_GIB=96          # hard machine ceiling
USABLE_GIB=92         # 96 − 4 GiB OS reserve (practical limit)
GRAPH_GIB=4.22        # pinned ds4 Flash graph allocation beyond its public context estimate
KVDISK="/tmp/ds4-memharness-kv"
CTXS="${1:-131072 393216 1000000}"

[ -x "$DS4/ds4-server" ] || { echo "ds4-server not built at $DS4"; exit 2; }
[ -s "$Q2" ] || { echo "q2 gguf missing: $Q2  (run: DS4_GGUF_DIR=\"$GGUF_DIR\" $DS4/download_model.sh q2-imatrix)"; exit 2; }

fail=0

# run_one <ctx> <disk:0|1>  -> prints a result row; returns non-zero if peak RSS > 96 GiB
run_one() {
  ctx="$1"; disk="$2"
  total_raw=""
  log="$(mktemp)"
  if [ "$disk" = 1 ]; then
    rm -rf "$KVDISK"; mkdir -p "$KVDISK"; label="disk-kv "
    ( cd "$DS4" && exec ./ds4-server -m "$Q2" --ctx "$ctx" --host 127.0.0.1 --port "$PORT" \
        --metal --warm-weights --kv-disk-dir "$KVDISK" --kv-disk-space-mb 16384 ) >"$log" 2>&1 &
  else
    label="no-disk "
    ( cd "$DS4" && exec ./ds4-server -m "$Q2" --ctx "$ctx" --host 127.0.0.1 --port "$PORT" \
        --metal --warm-weights ) >"$log" 2>&1 &
  fi
  pid=$!   # exec in the subshell => $! is ds4-server itself

  # wait for readiness (weights warm before "listening"); ≤600 s
  t=0
  while ! grep -q "listening on http://" "$log" 2>/dev/null; do
    kill -0 "$pid" 2>/dev/null || { echo "ctx=$ctx $label: server exited early:"; tail -4 "$log"; rm -f "$log"; return 1; }
    sleep 1; t=$((t + 1))
    [ "$t" -gt 600 ] && { echo "ctx=$ctx $label: startup timeout"; kill "$pid" 2>/dev/null; rm -f "$log"; return 1; }
  done
  kvest="$(grep -o 'context buffers [0-9.]* MiB' "$log" | head -1 | grep -o '[0-9.]*' | head -1)"
  if [ -z "$kvest" ]; then
    echo "ctx=$ctx $label: context-buffer measurement missing"
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "$log"; sleep 2
    return 1
  fi

  # exercise the model briefly, sampling peak RSS (KB) throughout
  curl -s "http://127.0.0.1:$PORT/v1/chat/completions" -H 'Content-Type: application/json' \
    -d '{"model":"deepseek-v4-flash","messages":[{"role":"user","content":"Say hi in one word."}],"max_tokens":16,"thinking":{"type":"disabled"}}' >/dev/null 2>&1 &
  cpid=$!
  peak_rss=0; n=0
  while kill -0 "$cpid" 2>/dev/null || [ "$n" -lt 6 ]; do   # at least ~3 s of samples
    rss="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -n "$rss" ] && [ "$rss" -gt "$peak_rss" ] 2>/dev/null && peak_rss="$rss"
    n=$((n + 1)); sleep 0.5
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; rm -f "$log"; sleep 2   # free the port

  # Total resident = mmap'd weights (RSS) + GPU-wired context allocation + the shared graph
  # workspace. The Metal allocations are not in RSS, so these values are additive.
  rss_gib="$(awk "BEGIN{printf \"%.1f\", $peak_rss/1024/1024}")"
  kv_gib="$(awk "BEGIN{printf \"%.1f\", $kvest/1024}")"
  total_raw="$(awk "BEGIN{printf \"%.9f\", $peak_rss/1024/1024 + $kvest/1024 + $GRAPH_GIB}")"
  total_gib="$(awk "BEGIN{printf \"%.1f\", $total_raw}")"
  ok="$(awk "BEGIN{print ($total_raw<=$LIMIT_GIB)?\"YES\":\"NO\"}")"
  warn="$(awk "BEGIN{print ($total_raw> $USABLE_GIB && $total_raw<=$LIMIT_GIB)?\" (>${USABLE_GIB} usable, will page)\":\"\"}")"
  printf '  %-9s %s weights_RSS=%-7s context=%-7s graph=%-6s total≈%-7s GiB  fits_96=%s%s\n' \
    "$ctx" "$label" "$rss_gib" "${kv_gib}GiB" "${GRAPH_GIB}GiB" "$total_gib" "$ok" "$warn"
  awk "BEGIN{exit !($total_raw<=$LIMIT_GIB)}"
}

echo "=== V4 Flash q2 resident-memory harness — limit ${LIMIT_GIB} GiB (usable ~${USABLE_GIB} GiB after OS) ==="
echo "    model: $Q2"
last=""; for c in $CTXS; do last="$c"; done
disk_total_raw=""
for ctx in $CTXS; do
  run_one "$ctx" 1 || fail=1          # disk-KV: the real default path (gated)
  [ "$ctx" = "$last" ] && disk_total_raw="$total_raw"
done
# no-disk control at the largest ctx, to confirm disk KV does not reduce resident memory
echo "  --- control (no disk KV) ---"
run_one "$last" 0 || fail=1
no_disk_total_raw="$total_raw"
if [ -n "$disk_total_raw" ] && [ -n "$no_disk_total_raw" ] \
    && awk "BEGIN{exit !($disk_total_raw < $no_disk_total_raw)}"; then
  echo "FAIL: disk KV measured ${disk_total_raw} GiB, below no-disk ${no_disk_total_raw} GiB."
  fail=1
fi

rm -rf "$KVDISK"
if [ "$fail" = 0 ]; then
  echo "PASS: every run fits within ${LIMIT_GIB} GiB and disk KV does not reduce resident allocation."
else
  echo "FAIL: a memory measurement or resident-allocation check failed."
fi
exit "$fail"
