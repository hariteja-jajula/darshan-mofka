#!/bin/bash
# study/multinode.sh -- how a multi-node Mofka broker and its partitioning affect
# the connector. Grounded in docs/MOFKA_NOTES.md.
#
# It brings up a multi-node broker with flock's MPI bootstrap (one bedrock per
# node, all forming one group), then runs the C workload through the connector
# against different partition layouts and records send count + walltime for each:
#
#   1 partition  on rank 0 only
#   N partitions one per server (round-robin across nodes)
#
# It also compares partition TYPE (memory vs on-disk default) on a single server.
# Everything is best-effort with fallbacks; results + notes go to
# results/multinode_<ts>/.
#
# Run in a PBS job with select>=2 (needs >=2 nodes for the multi-node broker).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
# shellcheck disable=SC1091
source env/server.sh; source env/workload.sh
module unload darshan 2>/dev/null || true
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"

STAMP="$(date +%Y%m%d_%H%M%S)"; RES="$ROOT/results/multinode_$STAMP"; mkdir -p "$RES"
LOG="$RES/multinode.log"; CSV="$RES/multinode.csv"; SUM="$RES/summary.txt"
exec > >(tee -a "$LOG") 2>&1
echo "workload,scenario,servers,partitions,ptype,sends,walltime_s,avg_push_us" > "$CSV"

NODES=$(sort -u "${PBS_NODEFILE:-/dev/null}" 2>/dev/null | wc -l); NODES=${NODES:-1}
echo "=== multinode study: $NODES node(s) in allocation, protocol=$MOFKA_PROTOCOL ==="
[ -e "$(darshan_lib)" ] || ./build.sh
DLIB="$(darshan_lib)"
"$CC" -O2 workloads/c/mofka_forward_smoke.c -o workloads/c/mofka_forward_smoke

SRV="$RES/broker"; mkdir -p "$SRV"
BROKER_PID=""
stop_broker() { [ -n "$BROKER_PID" ] && kill "$BROKER_PID" 2>/dev/null; pkill -f 'bedrock ' 2>/dev/null; sleep 2; BROKER_PID=""; }
trap stop_broker EXIT

# run the C workload through the connector against the current mofka.json; echo "sends walltime avgpush"
run_producer() {
    local tag="$1" group="$2" out="$RES/$tag"; mkdir -p "$out"
    local t0 t1; t0=$(date +%s.%N)
    env DARSHAN_ENABLE_NONMPI=1 DARSHAN_LOGPATH="$DARSHAN_LOGPATH" LD_PRELOAD="$DLIB" \
        DARSHAN_MOFKA_ENABLE=1 DARSHAN_MOFKA_GROUP_FILE="$group" DARSHAN_MOFKA_TOPIC=darshan \
        DARSHAN_MOFKA_BATCH=0 DARSHAN_MOFKA_MAX_BATCHES=64 DARSHAN_MOFKA_TIMING=1 \
        ./workloads/c/mofka_forward_smoke "$out/data" > "$out/out" 2> "$out/err" || true
    t1=$(date +%s.%N)
    local wall sends avgpush
    wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f", b-a}')
    sends=$(grep -c 'darshan-mofka\[timing\] send' "$out/err" 2>/dev/null || echo 0)
    avgpush=$(awk '/darshan-mofka\[timing\] send/{s+=$(NF-1);n++} END{if(n)printf "%.3f",s/n}' "$out/err")
    echo "$sends $wall $avgpush"
}

# -------- Part A: multi-node broker via flock MPI bootstrap --------
if [ "$NODES" -ge 2 ]; then
    echo "=== Part A: MPI-bootstrap broker across $NODES nodes ==="
    cp server/bedrock-config-mpi.json "$SRV/bedrock-config-mpi.json"
    ( cd "$SRV" && rm -f mofka.json
      mpirun -n "$NODES" --map-by ppr:1:node bedrock "$MOFKA_PROTOCOL" \
          -c bedrock-config-mpi.json -v info > "$SRV/bedrock.mpi.log" 2>&1 ) &
    BROKER_PID=$!
    for _ in $(seq 1 60); do [ -f "$SRV/mofka.json" ] && break; sleep 1; done
    if [ -f "$SRV/mofka.json" ]; then
        GROUP="$SRV/mofka.json"
        members=$(grep -oE '://[0-9.]+:[0-9]+' "$GROUP" | sort -u | wc -l)
        echo "  group formed with $members member address(es); mofka.json ready"
        # scenario A1: 1 partition on rank 0
        "$PY" -m mochi.mofka.mofkactl topic create darshan --groupfile "$GROUP" 2>/dev/null || true
        "$PY" -m mochi.mofka.mofkactl partition add darshan --rank 0 --type memory --groupfile "$GROUP" 2>/dev/null || true
        read s w a <<<"$(run_producer A1_1part "$GROUP")"
        echo "c,mpi_broker_1part,$members,1,memory,$s,$w,$a" >> "$CSV"
        echo "  A1 (1 partition):  sends=$s walltime=${w}s avg_push=${a}us"
        # scenario A2: add a partition on each remaining rank (one per server)
        np=1
        for r in $(seq 1 $((NODES-1))); do
            "$PY" -m mochi.mofka.mofkactl partition add darshan --rank "$r" --type memory --groupfile "$GROUP" 2>/dev/null \
                && np=$((np+1)) || echo "  (could not add partition on rank $r)"
        done
        read s w a <<<"$(run_producer A2_Npart "$GROUP")"
        echo "c,mpi_broker_Npart,$members,$np,memory,$s,$w,$a" >> "$CSV"
        echo "  A2 ($np partitions): sends=$s walltime=${w}s avg_push=${a}us"
    else
        echo "  MPI broker did not produce mofka.json in 60s -- see $SRV/bedrock.mpi.log"
        echo "c,mpi_broker_FAILED,$NODES,,,,," >> "$CSV"
    fi
    stop_broker
else
    echo "=== Part A skipped: only $NODES node in allocation (need >=2) ==="
fi

# -------- Part B: partition TYPE on a single-node broker (memory vs default) --------
echo "=== Part B: partition type memory vs default (single broker) ==="
for ptype in memory default; do
    rm -rf "$SRV/single"; mkdir -p "$SRV/single"
    cp server/bedrock-config.json "$SRV/single/bedrock-config.json"
    ( cd "$SRV/single" && rm -f mofka.json
      bedrock "$MOFKA_PROTOCOL" -c bedrock-config.json -v info > bedrock.log 2>&1 ) &
    BROKER_PID=$!
    for _ in $(seq 1 60); do [ -f "$SRV/single/mofka.json" ] && break; sleep 1; done
    if [ ! -f "$SRV/single/mofka.json" ]; then echo "  broker failed for $ptype"; stop_broker; continue; fi
    GROUP="$SRV/single/mofka.json"
    "$PY" -m mochi.mofka.mofkactl topic create darshan --groupfile "$GROUP" 2>/dev/null || true
    if [ "$ptype" = default ]; then
        "$PY" -m mochi.mofka.mofkactl partition add darshan --rank 0 --type default --abt-io io_controller --groupfile "$GROUP" 2>/dev/null \
          || { echo "  default partition add failed (needs abt-io); skipping"; stop_broker; continue; }
    else
        "$PY" -m mochi.mofka.mofkactl partition add darshan --rank 0 --type memory --groupfile "$GROUP" 2>/dev/null || true
    fi
    read s w a <<<"$(run_producer "B_$ptype" "$GROUP")"
    echo "c,single_broker,1,1,$ptype,$s,$w,$a" >> "$CSV"
    echo "  $ptype: sends=$s walltime=${w}s avg_push=${a}us"
    stop_broker
done

# -------- summary --------
{
  echo "Multi-node / partition study"
  echo "Allocation nodes: $NODES   protocol: $MOFKA_PROTOCOL"
  echo
  column -t -s, "$CSV"
  echo
  echo "Reading it: compare avg_push_us and walltime_s across scenarios."
  echo "  Part A shows the effect of spreading partitions across nodes (MPI broker)."
  echo "  Part B shows in-RAM (memory) vs on-disk (default) partition cost."
} | tee "$SUM"
echo "=== multinode study done -> $RES ==="
