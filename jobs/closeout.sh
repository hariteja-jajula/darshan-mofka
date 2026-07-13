#!/bin/bash
# closeout.sh -- one-command session close-up for the darshan->mofka overhead study.
# For every completed run under jobs/runs/, it (re)builds the computed overhead table,
# refreshes the plots, and prints the table + artifact list. Read-only w.r.t. the study
# inputs; it only (re)writes SUMMARY_AUTO.md / overhead_summary.csv / *.png in each run dir.
#
#   bash jobs/closeout.sh            # all completed runs
#   bash jobs/closeout.sh <rundir>   # just one
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$(command -v python3 || echo python3)"

wl_of(){ # guess the workload from a per-cell .out file
    local d="$1" f
    f="$(ls "$d"/mofka_*.out "$d"/none_*.out 2>/dev/null | head -1)"
    [ -n "$f" ] || { echo "?"; return; }
    grep -qm1 io_heavy   "$f" && { echo "io_heavy (Python)"; return; }
    grep -qm1 'io_mpi'   "$f" && { echo "io_mpi (MPI)"; return; }
    grep -qm1 'io_test'  "$f" && { echo "io_test (C)"; return; }
    echo "?"
}

show_one(){
    local d="$1"
    [ -f "$d/results.csv" ] || return
    local rows; rows=$(($(wc -l < "$d/results.csv")-1)); [ "$rows" -gt 0 ] || return
    echo; echo "================================================================"
    echo "  run: $(basename "$d")   cells: $rows   workload: $(wl_of "$d")"
    echo "================================================================"
    "$PY" "$ROOT/jobs/analyze_overhead.py" "$d" --md >/dev/null 2>&1 || true
    if [ -f "$d/SUMMARY_AUTO.md" ]; then
        sed -n '/== baselines/,/delta is streaming/p' "$d/SUMMARY_AUTO.md"
    else
        column -s, -t "$d/overhead_summary.csv" 2>/dev/null || cat "$d/results.csv"
    fi
    if "$PY" "$ROOT/jobs/plot_overhead.py" "$d" >/dev/null 2>&1; then
        echo "  plots: $(ls "$d"/*.png 2>/dev/null | wc -l) PNG(s) in $(basename "$d")/"
    else
        echo "  plots: skipped (matplotlib not available in $PY)"
    fi
}

echo "############ darshan -> mofka overhead study : closeout ############"
if [ "${1:-}" ]; then
    show_one "$1"
else
    for d in "$ROOT"/jobs/runs/*/; do show_one "$d"; done
fi
echo
echo "docs   : $ROOT/jobs/VISUALIZE.md"
echo "handoff: ~/internship/directives/session-startup-2026-07-12.md"
