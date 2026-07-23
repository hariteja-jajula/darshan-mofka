#!/bin/bash
# start_server.mpi.sh -- bring up a MULTI-NODE Mofka broker via flock's MPI
# bootstrap (bedrock-config.mpi.json: "bootstrap":"mpi", master DB gated to rank 0).
# Launched with PALS mpiexec, one bedrock rank per node; the ranks form ONE group
# and write a single mofka.json listing all member addresses.
#
# Requires being INSIDE a multi-node PBS allocation (uses $PBS_NODEFILE). Env:
#   MOFKA_SERVER_DIR   where mofka.json / bedrock.log go (default: server/)
#   MOFKA_NRANKS       # broker ranks = # nodes (default: node count in $PBS_NODEFILE)
#   MOFKA_PARTITIONS   partitions to add round-robin across ranks (default: NRANKS)
#   MOFKA_PART_TYPE    partition manager type (default: memory)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/env.sh"

SERVER_RUN_DIR="${MOFKA_SERVER_DIR:-$HERE}"; export MOFKA_SERVER_DIR="$SERVER_RUN_DIR"
mkdir -p "$SERVER_RUN_DIR"
CFG="$HERE/bedrock-config.mpi.json"
[ -f "$CFG" ] || { echo "missing $CFG"; exit 1; }
cp "$CFG" "$SERVER_RUN_DIR/bedrock-config.mpi.json"
cd "$SERVER_RUN_DIR"
rm -f mofka.json bedrock.pid bedrock.log

NRANKS="${MOFKA_NRANKS:-$( [ -n "${PBS_NODEFILE:-}" ] && sort -u "$PBS_NODEFILE" | wc -l || echo 1 )}"
PARTS="${MOFKA_PARTITIONS:-$NRANKS}"
PART_TYPE="${MOFKA_PART_TYPE:-memory}"

echo "starting MPI bedrock: $NRANKS ranks ($MOFKA_PROTOCOL) in $SERVER_RUN_DIR ..."
# One bedrock per node (--ppn 1). bash -c (NOT -l) so the env is inherited; cd into
# the run dir so the relative mofka.json lands there; absolute -c config path.
mpiexec -n "$NRANKS" --ppn 1 \
    bash -c "cd '$SERVER_RUN_DIR' && exec bedrock '$MOFKA_PROTOCOL' -c '$SERVER_RUN_DIR/bedrock-config.mpi.json' -v info" \
    > "$SERVER_RUN_DIR/bedrock.log" 2>&1 &
echo $! > bedrock.pid

for i in $(seq 1 120); do [ -f mofka.json ] && break; sleep 0.5; done
[ -f mofka.json ] || { echo "mofka.json never appeared; see bedrock.log"; tail -20 bedrock.log; exit 1; }

# form the topic + partitions round-robin across the ranks
mofkactl topic create darshan --groupfile mofka.json 2>/dev/null || true
for _p in $(seq 0 $((PARTS - 1))); do
    mofkactl partition add darshan --rank $((_p % NRANKS)) \
        --type "$PART_TYPE" --groupfile mofka.json || echo "  WARN: partition add rank $((_p % NRANKS)) failed"
done

NMEMB="$("$PY" - "$SERVER_RUN_DIR/mofka.json" <<'PY'
import json,sys
try: print(len(json.load(open(sys.argv[1])).get("members",[])))
except Exception: print(0)
PY
)"
echo "mofka(mpi) up: $NMEMB members | topic 'darshan' ($PARTS x $PART_TYPE part across $NRANKS ranks) | groupfile $SERVER_RUN_DIR/mofka.json (launcher pid $(cat bedrock.pid))"
