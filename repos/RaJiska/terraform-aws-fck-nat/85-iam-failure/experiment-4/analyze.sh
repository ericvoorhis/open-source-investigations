#!/usr/bin/env bash
# Summarise one run, or every run under results/ as a single table.
#
#   ./analyze.sh                     all runs (one account each), combined
#   ./analyze.sh results/<stamp>     a single run
#
# One fresh account per run, as in experiment-2 — but the module now carries the maintainer's proposed fix, so
# the expected shape is different. A working fix looks like: apply = ok on every trial, WHILE trial 1
# still shows activity = Failed with activities = 2. The launch failure is unchanged; only Terraform's
# reaction to it is. apply_time is the cost — a first apply that waits out the ASG's retry rather than
# erroring early.
#
# Nothing here needs a language runtime; it is BSD date plus awk, the same floor as run.sh.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
if [ $# -gt 0 ]; then RUNS=("$1"); else RUNS=($(ls -d "$ROOT"/results/*/ 2>/dev/null)); fi
[ "${#RUNS[@]}" -gt 0 ] && [ -f "${RUNS[0]}/results.tsv" ] || { echo "no runs found under results/" >&2; exit 1; }

# ISO8601 UTC -> epoch seconds, fraction preserved.
#
# BSD date cannot take the fractional part or the offset: given the full string it warns and silently
# drops them, which would round 2.35s and 4.17s to the same integer. So strip both, convert the whole
# seconds, and re-attach the fraction as a decimal for awk to add.
ep() {
  local t="$1" s f
  case "$t" in ""|-|NONE|None) printf 'NA'; return;; esac
  s=${t%%.*}; s=${s%%+*}; s=${s%Z}
  case "$t" in *.*) f=$(printf '%s' "$t" | sed -n 's/[^.]*\.\([0-9]\{1,6\}\).*/\1/p');; *) f="";; esac
  f=$(printf '0.%s' "${f:-0}")
  local e; e=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "$s" +%s 2>/dev/null)
  [ -z "$e" ] && { printf 'NA'; return; }
  printf '%s%s' "$e" "${f#0}"
}

# Seconds under two minutes stay in seconds because that is the resolution the race lives at; longer
# spans become minutes so a nine-minute-old role does not print as 540.00s.
delta() {
  local a b; a=$(ep "$1"); b=$(ep "$2")
  { [ "$a" = NA ] || [ "$b" = NA ]; } && { printf -- '-'; return; }
  awk -v a="$a" -v b="$b" 'BEGIN{ d=b-a; ad=(d<0?-d:d)
    if (ad<120) printf "%.2fs", d; else if (ad<7200) printf "%.1fm", d/60; else printf "%.1fh", d/3600 }'
}
secs() {  # bare seconds, for the summary arithmetic
  local a b; a=$(ep "$1"); b=$(ep "$2")
  { [ "$a" = NA ] || [ "$b" = NA ]; } && { printf ''; return; }
  awk -v a="$a" -v b="$b" 'BEGIN{ printf "%.2f", b-a }'
}

TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT

{
  printf 'account\ttrial\tslr_age_at_launch\tprofile_age\tasg->launch\tapply\tapply_time\tactivity\tactivities\n'
  for run in "${RUNS[@]}"; do
    [ -f "$run/results.tsv" ] || continue
    # Columns: 2 account_id  4 slr_before  5 slr_created_at  7 profile_created_at  9 apply_exit
    #          10 apply_seconds  11 asg_created_at  12 first_activity_at  13 first_activity_status
    #          15 activity_count
    awk -F'\t' 'NR>1 { print $1"\t"$2"\t"$4"\t"$5"\t"$7"\t"$9"\t"$10"\t"$11"\t"$12"\t"$13"\t"$15 }' "$run/results.tsv" \
    | while IFS=$'\t' read -r n acct before created prof exit_code secs asg first st acts; do
        # No space before the marker: column -t would split on it and shift the row.
        mark=""; [ "$before" = "NONE" ] && mark="*"
        [ "$exit_code" = "0" ] && verdict="ok" || verdict="FAIL"
        printf '%s\t%s\t%s%s\t%s\t%s\t%s\t%ss\t%s\t%s\n' \
          "$acct" "$n" "$(delta "$created" "$first")" "$mark" \
          "$(delta "$prof" "$first")" "$(delta "$asg" "$first")" \
          "$verdict" "$secs" "$st" "$acts"
        printf '%s\t%s\t%s\t%s\t%s\n' "$acct" "$n" "$verdict" "$st" "$secs" >> "$TMP"
      done
  done
} | column -t

echo
echo "  * the account's first-ever ASG: the service-linked role was created by this trial's apply."
echo

# The shape is the argument, so state it rather than leaving it to be eyeballed. A working fix means
# applies succeed WHILE the launch failure still occurs — if no failed activity appears at all, the
# account was not actually virgin and the run proves nothing.
awk -F'\t' '
  { n[$1]++; if ($3 == "FAIL") failed_applies++; if ($4 == "Failed") failed_acts++
    if ($2 == 1) { t1[$1] = $5 } else { later[++l] = $5 } }
  END {
    accts = 0; for (a in n) accts++
    printf "  accounts                    : %d\n", accts
    printf "  applies that FAILED         : %d   (a working fix means 0)\n", failed_applies + 0
    printf "  trials with a failed launch : %d   (expect 1 per account — the first)\n", failed_acts + 0
    s = 0; c = 0; for (a in t1) { s += t1[a]; c++ }
    if (c) printf "  first apply, mean duration  : %.0fs\n", s / c
    if (l) { s2 = 0; for (i = 1; i <= l; i++) s2 += later[i]
             printf "  later applies, mean duration: %.0fs   (difference is the cost of riding out the retry)\n", s2 / l }
  }' "$TMP"
