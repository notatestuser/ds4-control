#!/bin/sh
# Minimal ds4-server stand-in for tests. Args mirror the real flags; only --port is used.
PORT=8000
while [ $# -gt 0 ]; do case "$1" in --port) shift; PORT="$1";; *) ;; esac; shift; done
BODY='{"object":"list","data":[{"id":"deepseek-v4-flash"},{"id":"deepseek-v4-pro"}]}'
# tiny HTTP loop via nc; emit readiness AFTER binding
( while :; do printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' \
   "${#BODY}" "$BODY" | nc -l "$PORT" >/dev/null 2>&1 || sleep 0.2; done ) &
NCLOOP=$!
trap 'kill $NCLOOP 2>/dev/null; exit 0' TERM INT
sleep 0.3
echo "ds4-server: listening on http://127.0.0.1:$PORT" 1>&2
wait $NCLOOP
