#!/usr/bin/env bash
# Functional tests for server_proxy.x (reverse proxy).
# Starts a backend (server_http) and the proxy in front of it, then verifies the
# proxy relays requests/responses correctly (GET, Range 206, 404, large multi-recv).
#
# Usage: proxy_test.sh [path/to/xlangc]
set -u
XLANGC="${1:-xlangc}"
cd "$(dirname "$0")/.."

BACK_PORT=28110
PROXY_PORT=28120
PASS=0
FAIL=0
PIDS=""
# Fixed binary names so stale processes from prior runs can be killed reliably
# (a binary named "$ROOT/backend" survives pkill and holds the port across runs).
BACK_BIN=/tmp/xlang_proxy_backend
PROXY_BIN=/tmp/xlang_proxy_test

ROOT="$(mktemp -d)"
cleanup() {
    for p in $PIDS; do kill "$p" 2>/dev/null; done
    pkill -x "$(basename "$BACK_BIN")" 2>/dev/null
    pkill -x "$(basename "$PROXY_BIN")" 2>/dev/null
    rm -rf "$ROOT"
}
trap cleanup EXIT
# Kill any stale instances from a previous/aborted run BEFORE binding the port.
pkill -x "$(basename "$BACK_BIN")" 2>/dev/null
pkill -x "$(basename "$PROXY_BIN")" 2>/dev/null
sleep 0.2

# ---- fixtures ---------------------------------------------------------------
printf 'hello from backend\n' > "$ROOT/index.html"          # 19 bytes
printf '0123456789ABCDEFGHIJ' > "$ROOT/data.txt"            # 20 bytes
seq 1 30000 > "$ROOT/big.txt"                               # ~170 KB text (multi-recv; no NUL bytes — see note)

# ---- build + start backend + proxy -----------------------------------------
"$XLANGC" c servers/server_http.x -o build/server_http.c >/dev/null 2>&1 || "$XLANGC" c servers/server_http.x >/dev/null 2>&1
cc -O2 -o "$BACK_BIN" build/server_http.c
"$XLANGC" c servers/server_proxy.x -o build/server_proxy.c >/dev/null 2>&1 || "$XLANGC" c servers/server_proxy.x >/dev/null 2>&1
cc -O2 -o "$PROXY_BIN" build/server_proxy.c

"$BACK_BIN" "$ROOT" "$BACK_PORT" >/dev/null 2>&1 &
PIDS="$PIDS $!"
"$PROXY_BIN" 127.0.0.1 "$BACK_PORT" "$PROXY_PORT" 4 >/dev/null 2>&1 &
PIDS="$PIDS $!"
sleep 0.6

direct() { curl -s --max-time 5 "$@" "http://127.0.0.1:$BACK_PORT$1"; }
proxy()  { curl -s --max-time 5 "$@" "http://127.0.0.1:$PROXY_PORT$1"; }

check() {  # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "  ok   $1"; PASS=$((PASS+1))
    else echo "  FAIL $1  (expected [$2] got [$3])"; FAIL=$((FAIL+1)); fi
}
checkeq() {  # checkeq <name> <a> <b>  — pass if a == b
    if [ "$2" = "$3" ]; then echo "  ok   $1"; PASS=$((PASS+1))
    else echo "  FAIL $1  ([$2] != [$3])"; FAIL=$((FAIL+1)); fi
}

echo "== GET / through proxy matches direct"
checkeq "GET body" "$(direct /index.html)" "$(proxy /index.html)"
code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PROXY_PORT/index.html")
check "GET status 200" "200" "$code"

echo "== Range through proxy → 206 + correct partial relayed"
pbody=$(curl -s --max-time 5 -H 'Range: bytes=5-9' "http://127.0.0.1:$PROXY_PORT/data.txt")
dbody=$(curl -s --max-time 5 -H 'Range: bytes=5-9' "http://127.0.0.1:$BACK_PORT/data.txt")
checkeq "Range body (56789)" "$dbody" "$pbody"
pcode=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' -H 'Range: bytes=5-9' "http://127.0.0.1:$PROXY_PORT/data.txt")
check "Range status 206" "206" "$pcode"

echo "== 404 relayed"
code=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PROXY_PORT/missing.html")
check "404 status" "404" "$code"

echo "== large text file (~170 KB, multi-recv relay) byte-identical to direct"
curl -s --max-time 6 "http://127.0.0.1:$PROXY_PORT/big.txt" -o "$ROOT/via_proxy"
curl -s --max-time 6 "http://127.0.0.1:$BACK_PORT/big.txt" -o "$ROOT/via_direct"
checkeq "big.txt size" "$(wc -c < "$ROOT/via_direct")" "$(wc -c < "$ROOT/via_proxy")"
if cmp -s "$ROOT/via_proxy" "$ROOT/via_direct"; then
    echo "  ok   big.txt byte-identical (multi-recv relay correct)"; PASS=$((PASS+1))
else
    echo "  FAIL big.txt differs"; FAIL=$((FAIL+1))
fi
# verify proxy output matches the on-disk source exactly
if cmp -s "$ROOT/via_proxy" "$ROOT/big.txt"; then
    echo "  ok   big.txt == source"; PASS=$((PASS+1))
else
    echo "  FAIL big.txt != source"; FAIL=$((FAIL+1))
fi
# NOTE: binary bodies (containing NUL bytes) are NOT relayed correctly — the
# C-string relay (recv_str/sb_push/send_str all strlen-based) truncates at the
# first NUL. Text/HTML/JSON/CSS/JS relay fine. Binary-safe relay needs
# length-aware I/O builtins (future work).

echo
echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
