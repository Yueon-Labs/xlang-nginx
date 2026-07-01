#!/usr/bin/env bash
# Benchmark server_proxy.x: req/s through the proxy vs hitting the backend
# directly, to measure proxy overhead. Uses bench_py.py (keepalive load gen).
#
# Usage: proxy_bench.sh [path/to/xlangc]
set -u
XLANGC="${1:-xlangc}"
cd "$(dirname "$0")/.."

BACK_PORT=28130
PROXY_PORT=28140
BACK_BIN=/tmp/xlang_bench_backend
PROXY_BIN=/tmp/xlang_bench_proxy
ROOT="$(mktemp -d)"
trap 'pkill -f "$BACK_BIN" 2>/dev/null; pkill -f "$PROXY_BIN" 2>/dev/null; rm -rf "$ROOT"' EXIT
pkill -f "$BACK_BIN" 2>/dev/null
pkill -f "$PROXY_BIN" 2>/dev/null
sleep 0.2

printf 'hello\n' > "$ROOT/index.html"

"$XLANGC" c servers/server_http.x -o build/server_http.c >/dev/null 2>&1 || "$XLANGC" c servers/server_http.x >/dev/null 2>&1
cc -O2 -o "$BACK_BIN" build/server_http.c
"$XLANGC" c servers/server_proxy.x -o build/server_proxy.c >/dev/null 2>&1 || "$XLANGC" c servers/server_proxy.x >/dev/null 2>&1
cc -O2 -o "$PROXY_BIN" build/server_proxy.c

"$BACK_BIN" "$ROOT" "$BACK_PORT" >/dev/null 2>&1 &
"$PROXY_BIN" "$PROXY_PORT" 16 "127.0.0.1:$BACK_PORT" >/dev/null 2>&1 &
sleep 0.6

rps() {  # rps <port> <conc> → req/s integer
    python3 bench/bench_py.py "$1" 30000 "$2" 2>/dev/null | sed 's/.*req_s=\([0-9]*\).*/\1/'
}

echo "proxy req/s vs direct backend (keepalive, 30000 reqs, index.html=6 bytes)"
echo "---------------------------------------------------------------"
printf '%-10s' "target"
for c in 1 16 64; do printf '  c=%-3s' "$c"; done
echo
printf '%-10s' "direct"
for c in 1 16 64; do printf '  %6s' "$(rps "$BACK_PORT" "$c")"; done
echo
printf '%-10s' "proxy"
for c in 1 16 64; do printf '  %6s' "$(rps "$PROXY_PORT" "$c")"; done
echo
echo "---------------------------------------------------------------"
