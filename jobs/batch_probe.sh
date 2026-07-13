#!/bin/bash
# batch_probe.sh -- does the mofka producer batch_size change darshan->mofka overhead?
#
# batch_size is a CLIENT (producer) parameter, so we sweep it over the workload
# WITHOUT restarting the broker. For each value we run io_mpi under darshan->mofka
# with DARSHAN_MOFKA_TIMING=1 and report:
#   - events   : number of connector send() calls  (MUST be constant across all
#                batch values -- the proof that batching changes transport, not the
#                number of events pushed)
#   - send_avg : mean per-op time in the connector's send() (JSON build + enqueue)
#   - finalize : the final producer flush (drains whatever batch is still pending)
#
# Run on a COMPUTE node (verbs needs the fabric), AFTER rebuilding the connector:
#   cd ~/internship/darshan-mofka/darshan-mofka && source server/env.sh
#   cd darshan && ./build.sh && cd ..
#   bash jobs/batch_probe.sh
#
# Knobs:  NR=<ranks>  BATCHES="0 1 8 64 512"  REPEAT=<n>  MAXB=<max_num_batches>
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/server/env.sh"

LIB="$(darshan_lib)"
[ -n "$LIB" ] || { echo "no libdarshan -- build it: (cd $ROOT/darshan && ./build.sh)"; exit 1; }
NR="${NR:-128}"; BATCHES="${BATCHES:-0 1 8 64 512}"; REPEAT="${REPEAT:-3}"; MAXB="${MAXB:-0}"; TIMEOUT="${TIMEOUT:-120}"
SCRATCH="$(mktemp -d)"; darshan_ensure_logdir >/dev/null
echo "[probe] node=$(hostname -s) proto=$MOFKA_PROTOCOL ranks=$NR batches='$BATCHES' repeat=$REPEAT max_batches=$MAXB timeout=${TIMEOUT}s"
echo "[probe] lib=$LIB"

mpicc "$ROOT/workloads/io_mpi.c" -o "$ROOT/workloads/io_mpi" || { echo "io_mpi build failed"; exit 1; }

# one in-memory broker for the whole sweep (batch_size is client-side, no restart needed)
( cd "$ROOT/server" && ./start-server.sh ) || exit 1
GF="$ROOT/server/mofka.json"
trap '( cd "$ROOT/server" && ./stop-server.sh ) >/dev/null 2>&1' EXIT

printf "\n%-8s %-5s %-10s %-14s %-14s\n" batch rep events send_avg_us finalize_us
for B in $BATCHES; do
  for r in $(seq 1 "$REPEAT"); do
    d="$SCRATCH/b${B}_r${r}"; mkdir -p "$d"; o="$d/out.txt"
    timeout "$TIMEOUT" mpiexec -n "$NR" --bind-to none \
      -x DARSHAN_ENABLE_NONMPI=1 -x DARSHAN_MOFKA_ENABLE=1 \
      -x DARSHAN_MOFKA_GROUP_FILE="$GF" -x DARSHAN_MOFKA_TOPIC=darshan \
      -x DARSHAN_MOFKA_ENABLE_POSIX=1 -x DARSHAN_MOFKA_TIMING=1 \
      -x DARSHAN_MOFKA_BATCH="$B" -x DARSHAN_MOFKA_MAX_BATCHES="$MAXB" \
      -x DARSHAN_LOGPATH="$DARSHAN_LOGPATH" -x LD_PRELOAD="$LIB" \
      "$ROOT/workloads/io_mpi" "$d" > "$o" 2>&1
    rc=$?
    note=""; [ "$rc" = 124 ] && note="<TIMEOUT ${TIMEOUT}s, partial>"
    [ "$rc" != 0 ] && [ "$rc" != 124 ] && note="<rc=$rc>"
    awk -v b="$B" -v r="$r" -v note="$note" '
      /\[timing\] send/     {ss+=$3; sc++}
      /\[timing\] finalize/ {fs+=$3; fc++}
      END{ printf "%-8s %-5s %-10d %-14.3f %-14.3f  %s\n", b, r, sc, (sc?ss/sc:0), (fc?fs/fc:0), note }' "$o"
  done
done
echo "[probe] raw per-run stderr under $SCRATCH (grep '\[timing\]' there for p50/p99 etc.)"
