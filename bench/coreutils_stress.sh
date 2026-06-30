#!/usr/bin/env bash
# coreutils_stress.sh — run each stdin-processing xlang coreutil on 100k lines,
# time it, flag any that are pathologically slow (likely O(n²)). Usage: <bindir>
set -u
XB="$1"
N=100000
seq 1 $N | awk '{print "line-"$1 " word-"$1 " data "$1}' > /tmp/stress_in.txt
seq 1 $N | sort | uniq > /tmp/stress_sorted.txt   # for uniq (needs sorted)
printf "a\tb\tc\n" > /tmp/stress_tab.txt
seq 1 $N > /tmp/stress_num.txt

# run <tool-args...>  reading /tmp/stress_in.txt ; print ms
ms() {
  local label="$1"; shift
  local t=$(/usr/bin/time -f "%e" /bin/bash -c "$* < /tmp/stress_in.txt >/dev/null" 2>&1 >/dev/null)
  # t is seconds like 0.12 or 1.34
  printf "%-28s %ss\n" "$label" "$t"
}
msi() {  # input file is $1, rest are args+input
  local inp="$1" label="$2"; shift 2
  local t=$(/usr/bin/time -f "%e" /bin/bash -c "$* < $inp >/dev/null" 2>&1 >/dev/null)
  printf "%-28s %ss\n" "$label" "$t"
}

echo "=== stress @ ${N} lines (flag anything > ~1s as suspected O(n²)) ==="
export PATH="$XB"
ms  "cat"            "${XB}/cat"
ms  "tac"            "${XB}/tac"
ms  "rev"            "${XB}/rev"
ms  "head -1000"     "${XB}/head -1000"
ms  "tail -1000"     "${XB}/tail -1000"
ms  "wc -l"          "${XB}/wc -l"
ms  "sort"           "${XB}/sort"
ms  "sort -n"        "${XB}/sort -n"
msi "/tmp/stress_sorted.txt" "uniq"          "${XB}/uniq"
msi "/tmp/stress_sorted.txt" "uniq -c"       "${XB}/uniq -c"
ms  "tr -d aeiou"    "${XB}/tr -d aeiou"
ms  "tr a-z A-Z"     "${XB}/tr aeiou AEIOU"
ms  "cut -d- -f2"    "${XB}/cut -d- -f2"
ms  "fold -w 20"     "${XB}/fold -w 20"
ms  "nl"             "${XB}/nl"
ms  "grep word-500"  "${XB}/grep word-500"
msi "/tmp/stress_tab.txt" "expand"           "${XB}/expand"
ms  "base64"         "${XB}/base64"
echo "=== done ==="
rm -f /tmp/stress_in.txt /tmp/stress_sorted.txt /tmp/stress_tab.txt /tmp/stress_num.txt
