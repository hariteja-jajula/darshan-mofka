#!/bin/bash
#PBS -A radix-io
#PBS -q debug
#PBS -l select=2:system=polaris
#PBS -l walltime=00:12:00
#PBS -l filesystems=home:eagle
#PBS -l place=scatter
#PBS -N vni_probe
# THROWAWAY probe v3: verify collapse-to-LAST (shared job VNI) lets a client on N1 attach
# over ofi+cxi to a bedrock on N0 across SEPARATE --single-node-vni steps. Decides the runner fix.
set -u
REPO="/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight"
RA="$REPO/run_artifacts"; RUN="$RA/vniprobe"; RES="$RA/VNI_PROBE_RESULT"
rm -rf "$RUN"; mkdir -p "$RUN"; : > "$RES"
cd "$REPO" || { echo "FAIL: no repo" > "$RES"; exit 1; }
source env/server.sh --polaris >/dev/null 2>&1

mapfile -t NODES < <(sort -u "$PBS_NODEFILE")
N0="${NODES[0]}"; N1="${NODES[1]}"
printf '%s\n' "$N0" > "$RUN/hf0"; printf '%s\n' "$N1" > "$RUN/hf1"
cp server/bedrock-config.json "$RUN/bedrock-config.json"
SHOW='echo "RAW VNIS=[$SLINGSHOT_VNIS] host=$(hostname -s)" >&2;'
# collapse to LAST entry = shared job VNI (probe v2 showed last is constant across steps/nodes)
COLL_LAST='export SLINGSHOT_VNIS=${SLINGSHOT_VNIS##*,} SLINGSHOT_SVC_IDS=${SLINGSHOT_SVC_IDS##*,} SLINGSHOT_DEVICES=${SLINGSHOT_DEVICES##*,};'

{
echo "nodes: N0=$N0  N1=$N1"; echo

# ---- confirm the invariant: LAST VNI matches across two separate steps ----
echo "===== INV: last VNI shared across separate steps? ====="
mpiexec --single-node-vni --hostfile "$RUN/hf0" -n 1 --ppn 1 --cpu-bind none -- bash -c "$COLL_LAST $SHOW true" > "$RUN/i0.log" 2>&1
mpiexec --single-node-vni --hostfile "$RUN/hf1" -n 1 --ppn 1 --cpu-bind none -- bash -c "$COLL_LAST $SHOW true" > "$RUN/i1.log" 2>&1
v0="$(grep -oE 'VNIS=\[[^]]*\]' "$RUN/i0.log" | head -1)"; v1="$(grep -oE 'VNIS=\[[^]]*\]' "$RUN/i1.log" | head -1)"
echo "  N0 collapsed $v0 ; N1 collapsed $v1"
[ "$v0" = "$v1" ] && echo "  INV: OK (shared)" || echo "  INV: WARN (last VNI differs -> collapse-to-last wrong)"
echo

# ---- T-D: broker@N0 + real client@N1, BOTH --single-node-vni, BOTH collapse-to-last ----
echo "===== T-D: cross-node attach, collapse-to-last (job VNI) ====="
cd "$RUN"; rm -f mofka.json
mpiexec --single-node-vni --hostfile "$RUN/hf0" -n 1 --ppn 1 --cpu-bind none -- \
  bash -c "$COLL_LAST $SHOW exec bedrock ofi+cxi -c '$RUN/bedrock-config.json' -v info" > "$RUN/brokerD.log" 2>&1 &
BPID=$!
for _ in $(seq 1 60); do [ -f "$RUN/mofka.json" ] && break; sleep 1; done
if [ ! -f "$RUN/mofka.json" ]; then
    echo "  FAIL: brokerD never came up"; tail -10 "$RUN/brokerD.log" | sed 's/^/    /'
else
    addr="$(grep -oE 'ofi\+cxi://[^"]+' "$RUN/mofka.json" | head -1)"
    echo "  brokerD up: $addr  $(grep -oE 'RAW VNIS=\[[^]]*\]' "$RUN/brokerD.log" | head -1)"
    mpiexec --single-node-vni --hostfile "$RUN/hf1" -n 1 --ppn 1 --cpu-bind none -- \
      bash -c "cd '$REPO' && source env/server.sh --polaris >/dev/null 2>&1; $COLL_LAST $SHOW \
               mofkactl topic create probe --groupfile '$RUN/mofka.json' && \
               mofkactl partition add probe --rank 0 --type memory --groupfile '$RUN/mofka.json'" \
      > "$RUN/clientD.log" 2>&1
    cc=$?
    echo "  client exit=$cc; log tail:"; tail -8 "$RUN/clientD.log" | sed 's/^/    /'
    [ "$cc" = 0 ] && echo "  T-D: PASS -- cross-node CXI attach works via collapse-to-last" \
                  || echo "  T-D: FAIL -- client could not attach/operate over CXI"
fi
kill "$BPID" 2>/dev/null; pkill -f 'bedrock ' 2>/dev/null; sleep 2
echo
echo "===== SUMMARY ====="; grep -E 'INV:|T-D: (PASS|FAIL)' "$RES" 2>/dev/null | tail -3
} >> "$RES" 2>&1

pkill -f 'bedrock ' 2>/dev/null
echo "=== DONE ==="; tail -6 "$RES"
