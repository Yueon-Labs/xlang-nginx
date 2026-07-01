#!/usr/bin/env bash
# Load-balancing distribution test for server_proxy.x.
# Starts 2 backends (index.html = "A" / "B"), a proxy with BOTH as upstreams,
# sends many requests over fresh connections, and verifies they distribute
# across both backends (~50/50) — the nginx `upstream {}` round-robin behavior.
#
# Usage: lb_test.sh [path/to/xlangc]
set -u
XLANGC="${1:-xlangc}"
cd "$(dirname "$0")/.."

PA=28501
PB=28502
PP=28503
BACK_BIN=/tmp/xlang_lb_backend
PROXY_BIN=/tmp/xlang_lb_proxy
ROOT_A="$(mktemp -d)"
ROOT_B="$(mktemp -d)"
printf 'A' > "$ROOT_A/index.html"
printf 'B' > "$ROOT_B/index.html"
trap 'pkill -f "$BACK_BIN" 2>/dev/null; pkill -f "$PROXY_BIN" 2>/dev/null; rm -rf "$ROOT_A" "$ROOT_B"' EXIT
pkill -f "$BACK_BIN" 2>/dev/null
pkill -f "$PROXY_BIN" 2>/dev/null
sleep 0.2

"$XLANGC" c servers/server_http.x -o build/server_http.c >/dev/null 2>&1 || "$XLANGC" c servers/server_http.x >/dev/null 2>&1
cc -O2 -o "$BACK_BIN" build/server_http.c
"$XLANGC" c servers/server_proxy.x -o build/server_proxy.c >/dev/null 2>&1 || "$XLANGC" c servers/server_proxy.x >/dev/null 2>&1
cc -O2 -o "$PROXY_BIN" build/server_proxy.c

"$BACK_BIN" "$ROOT_A" "$PA" >/dev/null 2>&1 &
"$BACK_BIN" "$ROOT_B" "$PB" >/dev/null 2>&1 &
"$PROXY_BIN" "$PP" 16 "127.0.0.1:$PA" "127.0.0.1:$PB" >/dev/null 2>&1 &
sleep 0.7

N=200
A=0; B=0; OTHER=0
for _ in $(seq 1 $N); do
    body=$(curl -s --max-time 3 "http://127.0.0.1:$PP/index.html")
    case "$body" in
        A) A=$((A+1));;
        B) B=$((B+1));;
        *) OTHER=$((OTHER+1));;
    esac
done
echo "distribution over $N requests: A=$A B=$B other=$OTHER"

PASS=0; FAIL=0
lo=$((N/4)); hi=$((3*N/4))
[ "$A" -gt 0 ] && { echo "  ok   backend A reached"; PASS=$((PASS+1)); } || { echo "  FAIL backend A never reached"; FAIL=$((FAIL+1)); }
[ "$B" -gt 0 ] && { echo "  ok   backend B reached"; PASS=$((PASS+1)); } || { echo "  FAIL backend B never reached"; FAIL=$((FAIL+1)); }
if [ "$A" -ge "$lo" ] && [ "$A" -le "$hi" ]; then echo "  ok   A balanced ($A in [$lo,$hi])"; PASS=$((PASS+1)); else echo "  FAIL A imbalanced ($A outside [$lo,$hi])"; FAIL=$((FAIL+1)); fi
if [ "$B" -ge "$lo" ] && [ "$B" -le "$hi" ]; then echo "  ok   B balanced ($B in [$lo,$hi])"; PASS=$((PASS+1)); else echo "  FAIL B imbalanced ($B outside [$lo,$hi])"; FAIL=$((FAIL+1)); fi
echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
