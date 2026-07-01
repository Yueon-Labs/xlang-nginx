#!/usr/bin/env bash
# Functional tests for server_http.x (HTTP/1.1: GET/HEAD/Range/404/405/403).
#
# Builds the server with the xlang compiler, starts it on a random port against
# a temp docroot, and runs curl-based assertions. Exits non-zero on any failure.
#
# Usage: http_test.sh [path/to/xlangc] [port]
set -u

XLANGC="${1:-xlangc}"
PORT="${2:-28099}"
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

# ---- docroot fixtures -------------------------------------------------------
printf '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz' > "$ROOT/data.txt"   # 62 bytes
printf '<html><body>home</body></html>' > "$ROOT/index.html"
mkdir -p "$ROOT/sub"
printf 'second page' > "$ROOT/sub/page.html"

# ---- build & start ----------------------------------------------------------
echo "== building server_http with: $XLANGC"
"$XLANGC" c servers/server_http.x -o build/server_http.c 2>/dev/null \
    || "$XLANGC" c servers/server_http.x 2>/dev/null
cc -O2 -o "$ROOT/server_http" build/server_http.c || { echo "FAIL: cc"; exit 1; }

"$ROOT/server_http" "$ROOT" "$PORT" >/dev/null 2>&1 &
SERVER_PID=$!
sleep 0.4

check() {  # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  ok   $1"; PASS=$((PASS+1))
    else
        echo "  FAIL $1  (expected [$2] got [$3])"; FAIL=$((FAIL+1))
    fi
}

url() { printf 'http://%s:%s%s' "$HOST" "$PORT" "$1"; }

echo "== GET /index.html → 200 + body"
code=$(curl -s -o /dev/null -w '%{http_code}' "$(url /index.html)")
check "GET 200" "200" "$code"
body=$(curl -s "$(url /index.html)")
check "GET body" "<html><body>home</body></html>" "$body"

echo "== HEAD /index.html → 200, headers, no body"
code=$(curl -s -o /dev/null -w '%{http_code} %{size_download}' -I "$(url /index.html)")
check "HEAD 200" "200 0" "$code"
cl=$(curl -s -I "$(url /index.html)" | tr -d '\r' | grep -i '^content-length:' | awk '{print $2}')
check "HEAD Content-Length set" "30" "$cl"   # len("<html><body>home</body></html>") = 30

echo "== Range bytes=0-9 → 206 + Content-Range + 10-byte body"
hdr=$(curl -s -D - -o "$ROOT/r1" -H 'Range: bytes=0-9' "$(url /data.txt)")
code=$(printf '%s' "$hdr" | head -1 | tr -d '\r' | awk '{print $2}')
check "Range 206" "206" "$code"
cr=$(printf '%s' "$hdr" | tr -d '\r' | grep -i '^content-range:')
check "Content-Range" "Content-Range: bytes 0-9/62" "$cr"   # RFC 7233: bytes-unit SP range
check "Range body length" "10" "$(wc -c < "$ROOT/r1")"
check "Range body bytes" "0123456789" "$(cat "$ROOT/r1")"

echo "== Range bytes=50- (open-ended to EOF)"
hdr=$(curl -s -D - -o "$ROOT/r2" -H 'Range: bytes=50-' "$(url /data.txt)")
code=$(printf '%s' "$hdr" | head -1 | tr -d '\r' | awk '{print $2}')
check "Open range 206" "206" "$code"
check "Open range length" "12" "$(wc -c < "$ROOT/r2")"     # bytes 50..61 = 12 bytes
check "Open range body" "opqrstuvwxyz" "$(cat "$ROOT/r2")"

echo "== Range bytes=-5 (suffix: last 5 bytes)"
hdr=$(curl -s -D - -o "$ROOT/r3" -H 'Range: bytes=-5' "$(url /data.txt)")
code=$(printf '%s' "$hdr" | head -1 | tr -d '\r' | awk '{print $2}')
check "Suffix range 206" "206" "$code"
check "Suffix range body" "vwxyz" "$(cat "$ROOT/r3")"

echo "== Range bytes=5-3 (start>end → server treats as full 200)"
code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=5-3' "$(url /data.txt)")
check "Bad range → 200" "200" "$code"

echo "== GET missing → 404"
code=$(curl -s -o /dev/null -w '%{http_code}' "$(url /nope.html)")
check "404" "404" "$code"

echo "== POST → 405 Method Not Allowed"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$(url /data.txt)")
check "POST 405" "405" "$code"

echo "== path traversal /../ → 403"
code=$(curl -s -o /dev/null -w '%{http_code}' --path-as-is "$(url /../etc/passwd)")
check "Traversal 403" "403" "$code"

echo "== subdirectory file"
code=$(curl -s -o /dev/null -w '%{http_code}' "$(url /sub/page.html)")
check "Subdir 200" "200" "$code"

echo "== keepalive: 3 sequential requests over one connection"
out=$(PORT="$PORT" python3 - <<'PY'
import socket, os
s = socket.socket(); s.connect(("127.0.0.1", int(os.environ["PORT"])))
n = 0
for _ in range(3):
    s.sendall(b"GET /index.html HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n")
    buf = b""
    while b"\r\n\r\n" not in buf:
        c = s.recv(4096)
        if not c:
            break
        buf += c
    if b"200 OK" in buf:
        n += 1
print(n)
PY
)
check "keepalive 3 responses" "3" "$out"

echo
echo "RESULT: pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
