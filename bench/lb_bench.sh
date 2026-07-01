#!/usr/bin/env bash
# Benchmark: proxy load-balancing — throughput with 1 backend vs 2 backends.
# (2 backends should serve more aggregate req/s since each handles half the load.)
# Usage: lb_bench.sh [path/to/xlangc]
set -u
XLANGC="${1:-xlangc}"
cd "$(dirname "$0")/.."

PP=28640
BACK_BIN=/tmp/xlang_lb_bbench
PROXY_BIN=/tmp/xlang_lb_pbench
ROOT="$(mktemp -d)"
printf 'hello\n' > "$ROOT/index.html"
trap 'pkill -f "$BACK_BIN" 2>/dev/null; pkill -f "$PROXY_BIN" 2>/dev/null; rm -rf "$ROOT"' EXIT
pkill -f "$BACK_BIN" 2>/dev/null
pkill -f "$PROXY_BIN" 2>/dev/null
sleep 0.2

"$XLANGC" c servers/server_http.x -o build/server_http.c >/dev/null 2>&1 || "$XLANGC" c servers/server_http.x >/dev/null 2>&1
cc -O2 -o "$BACK_BIN" build/server_http.c
"$XLANGC" c servers/server_proxy.x -o build/server_proxy.c >/dev/null 2>&1 || "$XLANGC" c servers/server_proxy.x >/dev/null 2>&1
cc -O2 -o "$PROXY_BIN" build/server_proxy.c

rps() { python3 bench/bench_py.py "$1" 30000 "$2" 2>/dev/null | sed 's/.*req_s=\([0-9]*\).*/\1/'; }

echo "proxy req/s @ c=16: 1 backend vs 2 backends (keepalive, 30000 reqs)"

"$BACK_BIN" "$ROOT" 28631 >/dev/null 2>&1 &
"$PROXY_BIN" "$PP" 16 "127.0.0.1:28631" >/dev/null 2>&1 &
sleep 0.7
printf '  1 backend:   %s req/s\n' "$(rps "$PP" 16)"
pkill -f "$PROXY_BIN" 2>/dev/null; pkill -f "$BACK_BIN" 2>/dev/null; sleep 0.3

"$BACK_BIN" "$ROOT" 28632 >/dev/null 2>&1 &
"$BACK_BIN" "$ROOT" 28633 >/dev/null 2>&1 &
"$PROXY_BIN" "$PP" 16 "127.0.0.1:28632" "127.0.0.1:28633" >/dev/null 2>&1 &
sleep 0.7
printf '  2 backends:  %s req/s\n' "$(rps "$PP" 16)"
