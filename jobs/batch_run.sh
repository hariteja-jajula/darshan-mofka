#!/bin/bash
# batch_run.sh -- ONE self-contained command to measure how the mofka producer
# batch_size changes darshan->mofka overhead.
#
# Run on a COMPUTE node (verbs needs the fabric), after the connector is built:
#     bash jobs/batch_run.sh
#
# It sources the env, clears stray brokers, starts ONE in-memory broker, sweeps
# batch_size over io_mpi WITHOUT restarting the broker (batch is client-side),
# prints a table, and stops the broker on exit. Edit the CONFIG block to change
# the sweep. A cell that stalls hits the timeout, prints <TIMEOUT>, and the run
# continues (so it can never hang forever).
set -uo pipefail

# ============================ CONFIG (edit me) =============================
NR=16                    # MPI ranks (one per core)
BATCHES="0 1 8 64"       # producer batch sizes to sweep   (0 = adaptive)
REPEAT=2                 # repeats per batch value
MAXB=64                  # max_num_batches in flight (>= events/rank avoids stalls)
TIMEOUT=120              # per-cell wall-clock cap, seconds (stall -> <TIMEOUT>)
# ==========================================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/server/env.sh"

LIB="$(darshan_lib)"
[ -n "$LIB" ] || { echo "no libdarshan -- build it: (cd $ROOT/darshan && ./build.sh)"; exit 1; }
darshan_ensure_logdir >/dev/null
SCRATCH="$(mktemp -d)"                         # per-run logs (fine on tmpfs)
WLROOT="/tmp/ohd_wl_$$"; mkdir -p "$WLROOT"    # WORKLOAD output MUST be on a real fs:
                                               # darshan excludes tmpfs (e.g. /var/tmp/pbs),
                                               # which would hide all workload I/O.
echo "[run] node=$(hostname -s) proto=$MOFKA_PROTOCOL ranks=$NR batches='$BATCHES' repeat=$REPEAT max_batches=$MAXB timeout=${TIMEOUT}s"
echo "[run] lib=$LIB"

mpicc "$ROOT/workloads/io_mpi.c" -o "$ROOT/workloads/io_mpi" || { echo "io_mpi build failed"; exit 1; }

# clear stray brokers from earlier runs, then start ONE fresh in-memory broker
pkill -u "$USER" -x bedrock 2>/dev/null || true
sleep 1
( cd "$ROOT/server" && ./start-server.sh ) || { echo "broker failed; see server/bedrock.log"; exit 1; }
GF="$ROOT/server/mofka.json"
trap '( cd "$ROOT/server" && ./stop-server.sh ) >/dev/null 2>&1; rm -rf "$WLROOT"' EXIT

printf "\n%-8s %-5s %-10s %-14s %-14s %s\n" batch rep events send_avg_us finalize_us note
for B in $BATCHES; do
  for r in $(seq 1 "$REPEAT"); do
    d="$SCRATCH/b${B}_r${r}"; mkdir -p "$d"; o="$d/out.txt"
    w="$WLROOT/b${B}_r${r}"; mkdir -p "$w"   # workload writes here (/tmp, instrumented)
    timeout "$TIMEOUT" mpiexec -n "$NR" --bind-to none \
      -x DARSHAN_ENABLE_NONMPI=1 -x DARSHAN_MOFKA_ENABLE=1 \
      -x DARSHAN_MOFKA_GROUP_FILE="$GF" -x DARSHAN_MOFKA_TOPIC=darshan \
      -x DARSHAN_MOFKA_ENABLE_POSIX=1 -x DARSHAN_MOFKA_TIMING=1 \
      -x DARSHAN_MOFKA_BATCH="$B" -x DARSHAN_MOFKA_MAX_BATCHES="$MAXB" \
      -x DARSHAN_LOGPATH="$DARSHAN_LOGPATH" -x LD_PRELOAD="$LIB" \
      "$ROOT/workloads/io_mpi" "$w" > "$o" 2>&1
    rc=$?
    note=""; [ "$rc" = 124 ] && note="<TIMEOUT ${TIMEOUT}s, partial>"
    [ "$rc" != 0 ] && [ "$rc" != 124 ] && note="<rc=$rc>"
    awk -v b="$B" -v r="$r" -v note="$note" '
      /\[timing\] send/     {ss+=$3; sc++}
      /\[timing\] finalize/ {fs+=$3; fc++}
      END{ printf "%-8s %-5s %-10d %-14.3f %-14.3f  %s\n", b, r, sc, (sc?ss/sc:0), (fc?fs/fc:0), note }' "$o"
  done
done
echo "[run] raw per-run stderr under $SCRATCH"
