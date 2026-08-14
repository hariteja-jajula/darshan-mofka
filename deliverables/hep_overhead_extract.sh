#!/bin/bash
# hep_overhead_extract.sh <STUDY_dir> -- overhead summary for the HEP/SALT arms.
#
# The HEP workload runs inside an Apptainer container and emits a DIFFERENT timing
# format than the C/py workloads, so the generic deliverables/overhead_extract.sh
# does not apply here:
#   * wall clock is bracketed by WORK_SH_START_NS / WORK_SH_END_NS (the "_SH_"
#     variant, written by lib/run.sh around the container exec), not WORK_START_NS.
#   * the connector prints ONE aggregate line per rank at finalize --
#         darshan-mofka TIMING init_us=.. pushes=N push_total_us=.. push_avg_us=..
#     (uppercase, space-separated) -- not the per-event darshan-mofka[timing] lines,
#     so only aggregates are available (no per-push percentiles).
#
# Usage: bash deliverables/hep_overhead_extract.sh results/HEP_VERIFY
# Prints, per arm, the mean workload wall across reps + connector push aggregates,
# then the streaming-vs-baseline and runtimeonly-vs-baseline overhead deltas.
set -u
STUDY="${1:?usage: hep_overhead_extract.sh <STUDY_dir>}"

rep_wall() {        # echo wall seconds for one RUN dir, or nothing
    local r="$1" ws we
    ws=$(grep -hoE 'WORK_SH_START_NS [0-9]+' "$r"/workload.*.out 2>/dev/null | awk '{print $2}' | head -1)
    we=$(grep -hoE 'WORK_SH_END_NS [0-9]+'   "$r"/workload.*.out 2>/dev/null | awk '{print $2}' | head -1)
    [ -n "$ws" ] && [ -n "$we" ] && awk -v a="$ws" -v b="$we" 'BEGIN{printf "%.2f",(b-a)/1e9}'
}

# RUN1 in every arm is a container cold-cache outlier (first Apptainer launch on
# the node pays image warmup); RUN2+ are steady-state. We report BOTH the all-reps
# mean and the warm (RUN2+) mean so the overhead read is not distorted by warmup.
arm_wall_mean() {   # echo "<all_mean> <n_all> <warm_mean> <n_warm> <per_rep_csv>"
    local arm="$1" adir="$STUDY/$arm"
    local all=() warm=() r w n
    [ -d "$adir" ] || { echo "NA 0 NA 0 -"; return; }
    n=0
    for r in $(ls -d "$adir"/RUN* 2>/dev/null | sort -V); do
        [ -d "$r" ] || continue
        w=$(rep_wall "$r"); [ -z "$w" ] && continue
        n=$((n+1)); all+=("$w")
        [ "$(basename "$r")" != "RUN1" ] && warm+=("$w")
    done
    [ "${#all[@]}" -eq 0 ] && { echo "NA 0 NA 0 -"; return; }
    local csv am wm; csv=$(IFS=,; echo "${all[*]}")
    am=$(printf '%s\n' "${all[@]}"  | awk '{s+=$1;n++} END{printf "%.2f",(n?s/n:0)}')
    if [ "${#warm[@]}" -gt 0 ]; then
        wm=$(printf '%s\n' "${warm[@]}" | awk '{s+=$1;n++} END{printf "%.2f",(n?s/n:0)}')
    else wm="NA"; fi
    echo "$am ${#all[@]} $wm ${#warm[@]} $csv"
}

arm_push_agg() {    # echo "<total_pushes> <weighted_avg_us> <events>"
    local arm="$1" adir="$STUDY/$arm"
    [ -d "$adir" ] || { echo "0 0 0"; return; }
    # sum pushes and push_total across all ranks/reps; weighted avg = sum(total)/sum(pushes)
    awk '
      /darshan-mofka TIMING/ {
        for(i=1;i<=NF;i++){
          if($i ~ /^pushes=/){split($i,a,"=");p+=a[2]}
          if($i ~ /^push_total_us=/){split($i,a,"=");t+=a[2]}
        }
      }
      END{printf "%d %.3f", p, (p?t/p:0)}
    ' "$adir"/RUN*/workload.*.err 2>/dev/null
    # events across reps (sidecar preferred)
    local ev=0 c
    for c in "$adir"/RUN*/events.jsonl.count; do
        [ -f "$c" ] && ev=$((ev + $(grep -oE '[0-9]+' "$c" | head -1)))
    done
    echo " $ev"
}

echo "================ HEP overhead: $STUDY ================"
printf "%-13s %9s %9s %5s  %-26s\n" "arm" "all_mean" "warm_mean" "reps" "per_rep_s (RUN1=cold)"
declare -A WALL WARM
for arm in baseline runtimeonly streaming; do
    read -r am n wm nw csv <<<"$(arm_wall_mean "$arm")"
    WALL[$arm]="$am"; WARM[$arm]="$wm"
    printf "%-13s %9s %9s %5s  %-26s\n" "$arm" "$am" "$wm" "$n" "$csv"
done
echo
printf "%-13s %10s %14s %10s\n" "arm" "pushes" "push_avg_us" "events"
for arm in runtimeonly streaming; do
    read -r p a e <<<"$(arm_push_agg "$arm")"
    printf "%-13s %10s %14s %10s\n" "$arm" "$p" "$a" "$e"
done
echo
delta() {   # $1=label $2=baseline $3=arm
    if [ "$2" != "NA" ] && [ "$3" != "NA" ] && [ "$2" != "0" ]; then
        awk -v b="$2" -v v="$3" -v a="$1" \
          'BEGIN{printf "%-24s wall=%.2fs  delta=%+.2fs  overhead=%+.1f%%\n", a, v, v-b, 100*(v-b)/b}'
    else
        printf "%-24s (insufficient data: baseline=%s arm=%s)\n" "$1" "$2" "$3"
    fi
}
echo "---- overhead deltas (ALL reps, vs baseline) ----"
delta "runtimeonly (all)" "${WALL[baseline]:-NA}" "${WALL[runtimeonly]:-NA}"
delta "streaming   (all)" "${WALL[baseline]:-NA}" "${WALL[streaming]:-NA}"
echo
echo "---- overhead deltas (WARM reps RUN2+, vs baseline) ----"
delta "runtimeonly (warm)" "${WARM[baseline]:-NA}" "${WARM[runtimeonly]:-NA}"
delta "streaming   (warm)" "${WARM[baseline]:-NA}" "${WARM[streaming]:-NA}"
