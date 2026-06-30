#!/usr/bin/env bash
# coreutils_xcheck.sh — cross-check every xlang coreutil against its GNU
# counterpart across representative inputs. Reports PASS/FAIL per case and a
# summary. Run on Linux where both xlang-compiled binaries and GNU coreutils
# coexist. Usage: coreutils_xcheck.sh <dir-of-xlang-binaries>
set -u
XB="$1"   # directory with xlang-compiled coreutils (e.g. ~/xcut, ~/xsort ...)
PASS=0
FAIL=0
FAILED_CASES=()

# run_x <xlang-binary-name> <gnu-name> <input-file or -> <args...>
# compares stdout of "$XB/$x" to GNU "$g" for the same input+args.
ck() {
  local xname="$1" gname="$2" input="$3"; shift 3
  local args=("$@")
  local xo go
  if [ "$input" = "-" ]; then
    xo=$("${XB}/${xname}" "${args[@]}" 2>/dev/null)
    go=$("${gname}" "${args[@]}" 2>/dev/null)
  else
    xo=$("${XB}/${xname}" "${args[@]}" "$input" 2>/dev/null)
    go=$("${gname}" "${args[@]}" "$input" 2>/dev/null)
  fi
  if [ "$xo" = "$go" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_CASES+=("$xname ${args[*]} <$input>")
    echo "FAIL $xname ${args[*]} <$input>"
    echo "  xlang: $(echo "$xo" | head -2 | tr '\n' '|')"
    echo "  gnu  : $(echo "$go" | head -2 | tr '\n' '|')"
  fi
}

# stdin-based: ck_in <xname> <gname> <stdin-string> <args...>
ck_in() {
  local xname="$1" gname="$2" data="$3"; shift 3
  local xo go
  xo=$(printf "%s" "$data" | "${XB}/${xname}" "$@" 2>/dev/null)
  go=$(printf "%s" "$data" | "${gname}" "$@" 2>/dev/null)
  if [ "$xo" = "$go" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$xname $* <<EOF"); echo "FAIL $xname $* (stdin)"; fi
}

# ---- test data ----
printf "banana\napple\ncherry\napple\nbanana\n" > /tmp/xc_words.txt
printf "a,b,c\nd,e,f\ng,h,i\n" > /tmp/xc_csv.txt
printf "line1\nline2\nline3\nline4\nline5\n" > /tmp/xc_lines.txt
printf "hello world\nfoo bar baz\n" > /tmp/xc_text.txt

# ---- cases ----
ck_in echo   echo   "" hello world
ck_in seq    seq    "" 1 5
ck_in seq    seq    "" 1 2 10
ck_in seq    seq    "" -3 3
ck   cat    cat    /tmp/xc_lines.txt
ck   tac    tac    /tmp/xc_lines.txt
ck   rev    rev    /tmp/xc_text.txt
ck   head   head   /tmp/xc_lines.txt -3
ck   tail   tail   /tmp/xc_lines.txt -2
ck   wc     wc     /tmp/xc_lines.txt
ck   wc     wc     /tmp/xc_lines.txt -l
ck   wc     wc     /tmp/xc_text.txt -w
ck   sort   sort   /tmp/xc_words.txt
ck   sort   sort   /tmp/xc_words.txt -r
ck   uniq   uniq   /tmp/xc_words.txt
ck_in tr     tr     "hello" aeiou XXXXX
ck_in tr     tr     "hello world" -d aeiou
ck   cut    cut    /tmp/xc_csv.txt -d, -f1
ck   cut    cut    /tmp/xc_csv.txt -d, -f2,3
ck   fold   fold   /tmp/xc_text.txt -w 5
ck   nl     nl     /tmp/xc_lines.txt
ck_in factor  factor "" 60
ck_in factor  factor "" 13
ck_in factor  factor "" 100
ck_in expr    expr   "" 6 + 4
ck_in expr    expr   "" 7 '*' 8
ck   base64 base64 /tmp/xc_text.txt
ck   od     od     /tmp/xc_text.txt
ck   dirname dirname /a/b/c.txt
ck   basename basename /a/b/c.txt

echo ""
echo "=== SUMMARY: PASS=$PASS FAIL=$FAIL ==="
