#!/usr/bin/env bash
# Accurate server benchmark using the PURE-XLANG xwrk client (compiled C, no GIL —
# unlike bench_py.py which is client-bottlenecked and undercounts ~2-3x).
# Covers all three file servers (web/pro/http), the reverse proxy (1 backend),
# and load balancing (2 backends).
#
# Usage: xwrk_bench.sh [path/to/xlangc]
set -u
XLANGC="${1:-xlangc}"
cd "$(dirname "$0")/.."

SRV=/tmp/xwrkbench_srv
PROXY=/tmp/xwrkbench_proxy
XWRK=/tmp/xlang_xwrk
ROOT="$(mktemp -d)"
printf 'hello\n' > "$ROOT/index.html"
trap 'pkill -f "$SRV" 2>/dev/null; pkill -f "$PROXY" 2>/dev/null; rm -rf "$ROOT"' EXIT
pkill -f "$SRV" 2>/dev/null
pkill -f "$PROXY" 2>/dev/null
sleep 0.2

build_srv() {  # build_srv <stem>
    "$XLANGC" c "servers/$1.x" -o "build/$1.c" >/dev/null 2>&1
    cc -O2 -o "$SRV" "build/$1.c"
}
"$XLANGC" c servers/server_proxy.x -o build/server_proxy.c >/dev/null 2>&1; cc -O2 -o "$PROXY" build/server_proxy.c
if [ ! -x "$XWRK" ]; then
    XL=../xlang-linux
    "$XLANGC" c "$XL/coreutils/xwrk.x" -o build/xwrk.c >/dev/null 2>&1; cc -O2 -o "$XWRK" build/xwrk.c
fi

run() { "$XWRK" 127.0.0.1 "$1" /index.html 3 16 | sed -n 's/.*= \([0-9]*\) req\/s.*/\1/p'; }

echo "req/s @ c=16, 3s (xwrk pure-xlang client — accurate, no GIL bottleneck)"
echo "======================================================================="

for srv in server_web server_pro server_http; do
    build_srv "$srv"
    "$SRV" "$ROOT" 30001 >/dev/null 2>&1 &
    sleep 0.5
    printf '  %-20s %s\n' "$srv (direct):" "$(run 30001)"
    pkill -f "$SRV" 2>/dev/null; sleep 0.3
done

build_srv server_http  # backend for the proxy
"$SRV" "$ROOT" 30001 >/dev/null 2>&1 &
sleep 0.5
"$PROXY" 30002 16 127.0.0.1:30001 >/dev/null 2>&1 &
sleep 0.5
printf '  %-20s %s\n' "proxy -> 1 backend:" "$(run 30002)"
pkill -f "$PROXY" 2>/dev/null; sleep 0.3

"$SRV" "$ROOT" 30003 >/dev/null 2>&1 &
"$PROXY" 30004 16 127.0.0.1:30001 127.0.0.1:30003 >/dev/null 2>&1 &
sleep 0.5
printf '  %-20s %s\n' "proxy -> 2 backends:" "$(run 30004)"
echo "======================================================================="
