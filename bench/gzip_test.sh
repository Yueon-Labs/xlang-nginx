#!/usr/bin/env bash
# Test server_gzip.x gzip_static: serves a pre-compressed <file>.gz (binary-
# safe via sendfile, Content-Encoding: gzip) when the client sends
# Accept-Encoding: gzip; serves the plain file otherwise.
#
# Usage: gzip_test.sh [path/to/xlangc] [port]
set -u
XLANGC="${1:-xlangc}"
PORT="${2:-28102}"
HOST="127.0.0.1"
PASS=0
FAIL=0
SERVER_PID=""
ROOT="$(mktemp -d)"
cleanup() {
    [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$ROOT"
}
trap cleanup EXIT

# Fixture: a CSS file and its pre-gzipped twin.
printf 'body { color: red; margin: 0; padding: 10px; line-height: 1.5; }\n' > "$ROOT/style.css"
gzip -c "$ROOT/style.css" > "$ROOT/style.css.gz"

echo "== building server_gzip with: $XLANGC"
"$XLANGC" c servers/server_gzip.x -o build/server_gzip.c 2>/dev/null \
    || "$XLANGC" c servers/server_gzip.x 2>/dev/null
cc -O2 -o "$ROOT/server_gzip" build/server_gzip.c || { echo "FAIL: cc"; exit 1; }

"$ROOT/server_gzip" "$ROOT" "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
sleep 0.4

url() { printf 'http://%s:%s%s' "$HOST" "$PORT" "$1"; }
check() {
    if [ "$2" = "$3" ]; then echo "  ok   $1"; PASS=$((PASS+1)); else
        echo "  FAIL $1  (want [$2] got [$3])"; FAIL=$((FAIL+1)); fi
}

echo "== with Accept-Encoding: gzip → pre-compressed .gz served"
ce=$(curl -s -I -H 'Accept-Encoding: gzip' "$(url /style.css)" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-encoding"{print $2}')
check "Content-Encoding: gzip" "gzip" "$ce"
# Raw body must be byte-identical to the .gz file (no auto-decompress with -H).
curl -s -H 'Accept-Encoding: gzip' "$(url /style.css)" > "$ROOT/got.gz"
cmp -s "$ROOT/got.gz" "$ROOT/style.css.gz" && { echo "  ok   body == style.css.gz"; PASS=$((PASS+1)); } || { echo "  FAIL body != style.css.gz"; FAIL=$((FAIL+1)); }
# curl --compressed auto-decompresses back to the original text.
dec=$(curl -s --compressed "$(url /style.css)")
check "--compressed decompresses to original" "$(cat "$ROOT/style.css")" "$dec"

echo "== without Accept-Encoding → plain text (no Content-Encoding)"
ce2=$(curl -s -I "$(url /style.css)" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-encoding"{print $2}')
check "no Content-Encoding" "" "$ce2"
body=$(curl -s "$(url /style.css)")
check "body == style.css" "$(cat "$ROOT/style.css")" "$body"

echo
echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
