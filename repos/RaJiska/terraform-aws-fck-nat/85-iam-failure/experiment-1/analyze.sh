#!/usr/bin/env bash
# Derive the time deltas from a run's results.tsv.
#
#   ./analyze.sh [run-directory]     (defaults to the most recent run under results/)
#
# The headline is profile_age_at_launch: how old the instance profile was when AutoScaling attempted the
# launch. That is the quantity #85's hypothesis turns on — if instance-profile propagation causes the
# failure, a short age should produce it.
#
# Nothing here needs a language runtime; it is BSD date plus awk, the same floor as run.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
RUN="${1:-$(ls -d "$ROOT"/results/*/ 2>/dev/null | tail -1)}"
[ -n "$RUN" ] && [ -f "$RUN/results.tsv" ] || { echo "no results.tsv found (looked in ${RUN:-results/})" >&2; exit 1; }

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
# spans become minutes or days so a 25-day-old role does not print as 2168000s.
delta() {
  local a b; a=$(ep "$1"); b=$(ep "$2")
  { [ "$a" = NA ] || [ "$b" = NA ]; } && { printf -- '-'; return; }
  awk -v a="$a" -v b="$b" 'BEGIN{
    d=b-a; ad=(d<0?-d:d)
    if (ad<120)      printf "%.2fs", d
    else if (ad<7200) printf "%.1fm", d/60
    else if (ad<172800) printf "%.1fh", d/3600
    else             printf "%.1fd", d/86400
  }'
}

[ -f "$RUN/run-meta.txt" ] && sed 's/^/  /' "$RUN/run-meta.txt"
echo
{
  printf 'trial\tprofile_age_at_launch\tasg->launch\tslr_age\tresult\tactivities\n'
  # Columns: 4 slr_created_at  6 profile_created_at  9 asg_created_at  10 first_activity_at
  #          11 first_activity_status  12 activity_count
  awk -F'\t' 'NR>1 { print $1"\t"$4"\t"$6"\t"$9"\t"$10"\t"$11"\t"$12 }' "$RUN/results.tsv" \
  | while IFS=$'\t' read -r n slr prof asg first st acts; do
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" \
        "$(delta "$prof" "$first")" "$(delta "$asg" "$first")" \
        "$(delta "$slr" "$first")" "$st" "$acts"
    done
} | column -t
