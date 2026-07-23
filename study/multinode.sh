#!/bin/bash
# study/multinode.sh -- how a multi-node Mofka broker and partition count affect
# the connector. Grounded in docs/MOFKA_NOTES.md.
#
# Part A: bring up a broker spanning all allocated nodes using flock's MPI
#         bootstrap (one bedrock per node forming one group), then stream the C
#         workload against 1 partition vs one-partition-per-node.
# Part B: on a single-node broker, stream against 1 / 2 / 4 memory partitions to
#         see the effect of partition count.
#
# All measurements record send count, walltime, and the connector's average push
# time. Everything is best-effort with fallbacks; output goes to
# results/multinode_<ts>/ (multinode.csv + summary.txt + logs).
#
# Run in a PBS job with select>=2 for Part A.  bash study/multinode.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
# shellcheck disable=SC1091
source env/server.sh; source env/workload.sh
module unload darshan 2>/dev/null || true
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"

STAMP="$(date +%Y%m%d_%H%M%S)"; RES="$ROOT/results/multinode_$STAMP"; mkdir -p "$RES"
CSV="$RES/multinode.csv"; SUM="$RES/summary.txt"
echo "scenario,servers,partitions,ptype,sends,walltime_s,avg_push_us" > "$CSV"

NODES=$(sort -u "${PBS_NODEFILE:-/dev/null}" 2>/dev/null | wc -l); [ "$NODES" -ge 1 ] || NODES=1
echo "=== multinode study: $NODES node(s), protocol=$MOFKA_PROTOCOL, results -> $RES ==="
[ -e "$(darshan_lib)" ] || ./build.sh
DLIB="$(darshan_lib)"
"$CC" -O2 workloads/c/mofka_forward_smoke.c -o workloads/c/mofka_forward_smoke

BROKER_PID=""
stop_broker() { [ -n "$BROKER_PID" ] && kill "$BROKER_PID" 2>/dev/null; pkill -f 'bedrock ' 2>/dev/null; sleep 3; BROKER_PID=""; }
trap stop_broker EXIT

# run the C workload through the connector; echo "sends walltime avgpush" (never fails)
run_producer() {
    local tag="${1:-run}" group="${2:-}" out="$RES/${1:-run}"
    mkdir -p "$out"
    local t0 t1 wall sends avgpush
    t0=$(date +%s.%N)
    env DARSHAN_ENABLE_NONMPI=1 DARSHAN_LOGPATH="$DARSHAN_LOGPATH" LD_PRELOAD="$DLIB" \
        DARSHAN_MOFKA_ENABLE=1 DARSHAN_MOFKA_GROUP_FILE="$group" DARSHAN_MOFKA_TOPIC=darshan \
        DARSHAN_MOFKA_BATCH=0 DARSHAN_MOFKA_MAX_BATCHES=64 DARSHAN_MOFKA_TIMING=1 \
        ./workloads/c/mofka_forward_smoke "$out/data" > "$out/out" 2> "$out/err" || true
    t1=$(date +%s.%N)
    wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f", b-a}')
    sends=$(grep -c 'darshan-mofka\[timing\] send' "$out/err" 2>/dev/null); sends=${sends:-0}
    avgpush=$(awk '/darshan-mofka\[timing\] send/{s+=$(NF-1);n++} END{if(n)printf "%.3f",s/n; else printf "NA"}' "$out/err")
    printf '%s %s %s\n' "$sends" "$wall" "$avgpush"
}
mctl() { "$PY" -m mochi.mofka.mofkactl "$@"; }

# ---------------- Part A: multi-node broker via flock MPI bootstrap ----------------
if [ "$NODES" -ge 2 ]; then
    echo "=== Part A: MPI-bootstrap broker across $NODES nodes ==="
    SRV="$RES/mpi_broker"; mkdir -p "$SRV"
    cp server/bedrock-config-mpi.json "$SRV/"
    sort -u "$PBS_NODEFILE" > "$SRV/hostfile"
    # openmpi here spawns remote ranks over ssh; relax host-key checking so it can.
    export OMPI_MCA_plm_rsh_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    ( cd "$SRV" && rm -f mofka.json
      mpirun --hostfile hostfile -np "$NODES" --map-by ppr:1:node \
             bedrock "$MOFKA_PROTOCOL" -c bedrock-config-mpi.json -v info > "$SRV/bedrock.mpi.log" 2>&1 ) &
    BROKER_PID=$!
    for _ in $(seq 1 90); do [ -f "$SRV/mofka.json" ] && break; sleep 1; done
    if [ -f "$SRV/mofka.json" ]; then
        GROUP="$SRV/mofka.json"
        members=$(grep -oE '://[0-9.]+:[0-9]+' "$GROUP" | sort -u | wc -l)
        echo "  group formed: $members member address(es)"
        mctl topic create darshan --groupfile "$GROUP" 2>/dev/null || true
        mctl partition add darshan --rank 0 --type memory --groupfile "$GROUP" 2>/dev/null || true
        read -r s w a <<<"$(run_producer A_1part "$GROUP")"
        echo "mpi_broker,$members,1,memory,$s,$w,$a" >> "$CSV"
        echo "  1 partition (rank 0):     sends=$s walltime=${w}s avg_push=${a}us"
        np=1
        for r in $(seq 1 $((NODES-1))); do
            mctl partition add darshan --rank "$r" --type memory --groupfile "$GROUP" 2>/dev/null && np=$((np+1)) || true
        done
        read -r s w a <<<"$(run_producer A_Npart "$GROUP")"
        echo "mpi_broker,$members,$np,memory,$s,$w,$a" >> "$CSV"
        echo "  $np partitions (1/node):    sends=$s walltime=${w}s avg_push=${a}us"
    else
        echo "  MPI broker did not form a group in 90s -- see $SRV/bedrock.mpi.log"
        echo "  (head of log:)"; head -8 "$SRV/bedrock.mpi.log" 2>/dev/null | sed 's/^/    /'
        echo "mpi_broker_FAILED,$NODES,,,,," >> "$CSV"
    fi
    stop_broker
else
    echo "=== Part A skipped: only 1 node in allocation (need >=2) ==="
fi

# ---------------- Part B: partition count on a single-node broker ----------------
echo "=== Part B: 1 / 2 / 4 memory partitions on a single broker ==="
for npart in 1 2 4; do
    SRV="$RES/single_${npart}p"; mkdir -p "$SRV"
    cp server/bedrock-config.json "$SRV/"
    ( cd "$SRV" && rm -f mofka.json
      bedrock "$MOFKA_PROTOCOL" -c bedrock-config.json -v info > bedrock.log 2>&1 ) &
    BROKER_PID=$!
    for _ in $(seq 1 60); do [ -f "$SRV/mofka.json" ] && break; sleep 1; done
    if [ ! -f "$SRV/mofka.json" ]; then echo "  broker failed for ${npart}p"; stop_broker; continue; fi
    GROUP="$SRV/mofka.json"
    mctl topic create darshan --groupfile "$GROUP" 2>/dev/null || true
    for _ in $(seq 1 "$npart"); do mctl partition add darshan --rank 0 --type memory --groupfile "$GROUP" 2>/dev/null || true; done
    read -r s w a <<<"$(run_producer "B_${npart}p" "$GROUP")"
    echo "single_broker,1,$npart,memory,$s,$w,$a" >> "$CSV"
    echo "  ${npart} partition(s): sends=$s walltime=${w}s avg_push=${a}us"
    stop_broker
done

{
  echo "Multi-node / partition study    nodes=$NODES  protocol=$MOFKA_PROTOCOL"
  echo
  column -t -s, "$CSV" 2>/dev/null || cat "$CSV"
  echo
  echo "Part A: effect of spreading partitions across nodes (real multi-node broker)."
  echo "Part B: effect of partition count on one server (they share the server's pools,"
  echo "        so the docs expect little change until partitions live on separate servers)."
} | tee "$SUM"
echo "=== multinode study done -> $RES ==="
