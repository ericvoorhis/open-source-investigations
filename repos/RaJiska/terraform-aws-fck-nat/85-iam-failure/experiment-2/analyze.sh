#!/usr/bin/env bash
# Summarise one run, or every run under results/ as a single table.
#
#   ./analyze.sh                     all runs (one account each), combined
#   ./analyze.sh results/<stamp>     a single run
#
# The design is one fresh account per run, so combining runs is what produces the argument: if the
# account's first-ever ASG is what fails, then trial 1 fails in every account and no later trial does.
# A race condition would scatter failures through the sequence instead.
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
  printf 'account\ttrial\tslr_age_at_launch\tprofile_age\tasg->launch\tapply\tactivity\tself_heal\n'
  for run in "${RUNS[@]}"; do
    [ -f "$run/results.tsv" ] || continue
    # Columns: 2 account_id  4 slr_before  5 slr_created_at  7 profile_created_at  10 asg_created_at
    #          11 first_activity_at  12 first_activity_status  13 recovery_at
    awk -F'\t' 'NR>1 { print $1"\t"$2"\t"$4"\t"$5"\t"$7"\t"$9"\t"$10"\t"$11"\t"$12"\t"$13 }' "$run/results.tsv" \
    | while IFS=$'\t' read -r n acct before created prof exit_code asg first st recovery; do
        # No space before the marker: column -t would split on it and shift the row.
        mark=""; [ "$before" = "NONE" ] && mark="*"
        [ "$exit_code" = "0" ] && verdict="ok" || verdict="FAIL"
        printf '%s\t%s\t%s%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$acct" "$n" "$(delta "$created" "$first")" "$mark" \
          "$(delta "$prof" "$first")" "$(delta "$asg" "$first")" \
          "$verdict" "$st" "$(delta "$first" "$recovery")"
        printf '%s\t%s\t%s\t%s\n' "$acct" "$n" "$verdict" "$(secs "$first" "$recovery")" >> "$TMP"
      done
  done
} | column -t

echo
echo "  * the account's first-ever ASG: the service-linked role was created by this trial's apply."
echo

# The shape is the argument, so state it rather than leaving it to be eyeballed.
awk -F'\t' '
  { n[$1]++; if ($2==1) { first[$1]=$3 } ; if ($3=="FAIL") fails[$1]++ ; if ($4!="") { h[++hn]=$4 } }
  END {
    accts=0; t1fail=0; later=0
    for (a in n) { accts++; if (first[a]=="FAIL") t1fail++; f=(a in fails)?fails[a]:0; later+=f-((first[a]=="FAIL")?1:0) }
    printf "  accounts            : %d\n", accts
    printf "  trial 1 failed      : %d/%d\n", t1fail, accts
    printf "  later trials failed : %d\n", later
    if (hn) { lo=hi=h[1]; s=0; for(i=1;i<=hn;i++){ if(h[i]<lo)lo=h[i]; if(h[i]>hi)hi=h[i]; s+=h[i] }
      printf "  self-heal (n=%d)     : min %.1fs  max %.1fs  mean %.1fs\n", hn, lo, hi, s/hn
      printf "  vs 5m capacity wait : %s\n", (hi<300 ? "all within the maintainer'\''s shortened timeout" : "AT LEAST ONE EXCEEDS IT") }
  }' "$TMP"
