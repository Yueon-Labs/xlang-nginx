#!/usr/bin/env bash
# Compare req/s of server_http vs server_pro vs server_web on the same host.
# Builds each with xlangc, runs bench_py.py (keepalive load gen) at several
# concurrency levels, prints a table.
#
# Usage: http_bench.sh [path/to/xlangc]
set -u
XLANGC="${1:-xlangc}"
cd "$(dirname "$0")/.."          # repo root

# ---- build ------------------------------------------------------------------
build() {  # build <stem>
    "$XLANGC" c "servers/$1.x" -o "build/$1.c" >/dev/null 2>&1 || "$XLANGC" c "servers/$1.x" >/dev/null 2>&1
    cc -O2 -o "/tmp/$1" "build/$1.c"
}
echo "== building servers"
build server_http
build server_pro
build server_web

# ---- docroot (index.html must contain "hello" for bench_py.py) --------------
ROOT=$(mktemp -d)
printf 'hello\n' > "$ROOT/index.html"
DATA=$(printf 'hello\n'); for i in $(seq 1 1000); do DATA="${DATA}hello\n"; done
printf 'hello\n' > "$ROOT/big.txt"   # served via Range tests if needed
trap 'pkill -x server_http 2>/dev/null; pkill -x server_pro 2>/dev/null; pkill -x server_web 2>/dev/null; rm -rf "$ROOT"' EXIT

run() {  # run <binary> <port> <label>
    local bin="$1" port="$2" label="$3"
    "$bin" "$ROOT" "$port" >/dev/null 2>&1 &
    local pid=$!
    sleep 0.4
    printf '%-14s' "$label"
    for c in 1 16 64; do
        local r=$(python3 bench/bench_py.py "$port" 30000 "$c" 2>/dev/null | sed 's/.*req_s=\([0-9]*\).*/\1/')
        printf '  c=%-2s %8s' "$c" "${r:-ERR}"
    done
    echo
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    sleep 0.2
}

echo
echo "req/s (keepalive, 30000 requests each), docroot=index.html(6 bytes)"
echo "-------------------------------------------------------------------"
run /tmp/server_http 29000 "server_http"
run /tmp/server_pro  28083 "server_pro"
run /tmp/server_web  28082 "server_web"
echo "-------------------------------------------------------------------"
rm -rf "$ROOT"
