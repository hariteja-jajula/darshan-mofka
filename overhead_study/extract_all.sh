#!/bin/bash
# extract_all.sh -- aggregate the connector-overhead breakdown across every OVH_* run.
# For each results/OVH_*/<arm>/RUN*, runs deliverables/overhead_extract.sh and prints
# one table row: study | arm/run | init(avg/max) finalize | push(p50/p99/max) work_s VERDICT.
#
# The FIRST rep (RUN1) is a cold-start throwaway (node/broker/fs warmup + compute
# jitter) and is EXCLUDED by default -- only RUN2+ ("warm") are reported. Set
# INCLUDE_COLD=1 to show RUN1 too (marked *cold).
#
# push/send: p50/p99 (robust to fat-tail drain-thread outliers) instead of just avg.
# init/finalize: avg + max across ranks (max = slowest rank).
# Usage: bash overhead_study/extract_all.sh            [results_glob]
#        INCLUDE_COLD=1 bash overhead_study/extract_all.sh
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EX="$ROOT/deliverables/overhead_extract.sh"
GLOB="${1:-$ROOT/results/OVH_*}"
INCLUDE_COLD="${INCLUDE_COLD:-0}"

printf "%-24s %-14s | %9s %9s %8s | %9s %9s %10s | %9s  %s\n" \
    STUDY ARM/RUN init_avg init_max fin_us push_p50 push_p99 push_max work_s VERDICT
printf '%.0s-' {1..132}; echo
for study in $GLOB; do
    [ -d "$study" ] || continue
    sname="$(basename "$study")"
    for arm in baseline runtimeonly streaming; do
        # numeric-sort RUN dirs so RUN1 is unambiguously first (the cold rep)
        mapfile -t runs < <(find "$study/$arm" -maxdepth 1 -name 'RUN*' -type d 2>/dev/null | sort -V)
        idx=0
        for run in "${runs[@]}"; do
            [ -d "$run" ] || continue
            idx=$((idx+1))
            rname="$(basename "$run")"
            cold=0; [ "$idx" -eq 1 ] && cold=1
            if [ "$cold" = 1 ] && [ "$INCLUDE_COLD" != 1 ]; then continue; fi
            out="$($EX "$run" 2>/dev/null)"
            ia=$(sed -n 's/.*init_us=\([0-9.]*\).*/\1/p'          <<<"$out")
            im=$(sed -n 's/.*init_max_us=\([0-9.]*\).*/\1/p'      <<<"$out")
            fin=$(sed -n 's/.*finalize_us=\([0-9.]*\).*/\1/p'     <<<"$out")
            pp50=$(grep '^push:' <<<"$out" | sed -n 's/.*p50_us=\([0-9.]*\).*/\1/p')
            pp99=$(grep '^push:' <<<"$out" | sed -n 's/.*p99_us=\([0-9.]*\).*/\1/p')
            pmax=$(grep '^push:' <<<"$out" | sed -n 's/.*max_us=\([0-9.]*\).*/\1/p')
            work=$(sed -n 's/.*work_s=\([0-9.]*\).*/\1/p'         <<<"$out")
            verdict=$(grep -oE 'VERDICT: [A-Z]+.*' <<<"$out" | head -1)
            # display label: on-disk arm dir stays "runtimeonly" (feeder/state depend
            # on it), but report it as the clearer "darshan-only".
            disp="$arm"; [ "$arm" = runtimeonly ] && disp="darshan-only"
            tag="$disp/$rname"; [ "$cold" = 1 ] && tag="$tag*cold"
            printf "%-24s %-14s | %9s %9s %8s | %9s %9s %10s | %9s  %s\n" \
                "$sname" "$tag" \
                "${ia:-–}" "${im:-–}" "${fin:-–}" \
                "${pp50:-–}" "${pp99:-–}" "${pmax:-–}" "${work:-–}" "${verdict:-–}"
        done
    done
done
