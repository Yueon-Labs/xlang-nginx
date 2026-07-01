#!/usr/bin/env bash
# Test server_vhost.x path routing (nginx location{}-style). Two backends serve
# different content; routes /api -> A, / -> B. Verifies requests route to the
# right backend by URL prefix.
#
# Usage: vhost_test.sh [path/to/xlangc]
set -u
XLANGC="${1:-xlangc}"
cd "$(dirname "$0")/.."

PASS=0; FAIL=0
mkdir -p build
"$XLANGC" c servers/server_http.x  -o build/server_http.c  >/dev/null 2>&1; cc -O2 -o /tmp/vh_srv build/server_http.c
"$XLANGC" c servers/server_vhost.x -o build/server_vhost.c >/dev/null 2>&1; cc -O2 -o /tmp/vh     build/server_vhost.c

RA="$(mktemp -d)"; RB="$(mktemp -d)"
mkdir -p "$RA/api"; printf 'from-api\n'  > "$RA/api/index.html"
printf 'from-root\n' > "$RB/index.html"
/tmp/vh_srv "$RA" 31001 >/dev/null 2>&1 & SA=$!
/tmp/vh_srv "$RB" 31002 >/dev/null 2>&1 & SB=$!
/tmp/vh 31000 4 /api=127.0.0.1:31001 /=127.0.0.1:31002 >/dev/null 2>&1 & VP=$!
trap 'kill $SA $SB $VP 2>/dev/null; rm -rf "$RA" "$RB"' EXIT
sleep 0.6

check() { [ "$2" = "$3" ] && { echo "  ok   $1"; PASS=$((PASS+1)); } || { echo "  FAIL $1 (exp [$2] got [$3])"; FAIL=$((FAIL+1)); }; }

echo "== path routing (/api -> backend A, / -> backend B)"
check "GET /api/index.html -> A" "from-api"  "$(curl -s --max-time 3 http://127.0.0.1:31000/api/index.html | tr -d '\n')"
check "GET /index.html    -> B" "from-root" "$(curl -s --max-time 3 http://127.0.0.1:31000/index.html | tr -d '\n')"
check "GET /              -> B" "from-root" "$(curl -s --max-time 3 http://127.0.0.1:31000/ | tr -d '\n')"

echo
echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
