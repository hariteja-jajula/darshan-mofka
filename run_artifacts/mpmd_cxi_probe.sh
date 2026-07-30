#!/bin/bash
#PBS -A radix-io
#PBS -q debug
#PBS -l select=2:system=polaris
#PBS -l walltime=00:12:00
#PBS -l filesystems=home:eagle
#PBS -l place=scatter
#PBS -N mpmd_cxi
# THROWAWAY: does cross-node ofi+cxi attach work when broker(N0) + client(N1) are ONE MPMD
# mpiexec step (shared step VNI)? Contrast with two-step T-D (failed VNI_NOT_FOUND).
# Writes run_artifacts/MPMD_CXI_RESULT.
set -u
REPO="/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight"
RA="$REPO/run_artifacts"; RUN="$RA/mpmdprobe"; RES="$RA/MPMD_CXI_RESULT"
rm -rf "$RUN"; mkdir -p "$RUN"; : > "$RES"
cd "$REPO" || { echo "FAIL: no repo" > "$RES"; exit 1; }
source env/server.sh --polaris >/dev/null 2>&1
mapfile -t NODES < <(sort -u "$PBS_NODEFILE")
N0="${NODES[0]}"; N1="${NODES[1]}"
printf '%s\n' "$N0" > "$RUN/hf0"; printf '%s\n' "$N1" > "$RUN/hf1"
cp server/bedrock-config.json "$RUN/bedrock-config.json"

# rank0 (N0): bring up bedrock over cxi, keep it alive; write a done-marker after topic exists.
# COLLAPSE to first VNI: in a single MPMD step both ranks see the SAME list, so first is
# identical on both nodes -> shared rgroup + margo's multi-VNI bug avoided.
cat > "$RUN/rank0.sh" <<R0
#!/bin/bash
cd "$RUN"; rm -f mofka.json ready.flag
echo "rank0 RAW VNIS=[\$SLINGSHOT_VNIS] host=\$(hostname -s)" >&2
export SLINGSHOT_VNIS=\${SLINGSHOT_VNIS%%,*} SLINGSHOT_SVC_IDS=\${SLINGSHOT_SVC_IDS%%,*} SLINGSHOT_DEVICES=\${SLINGSHOT_DEVICES%%,*}
bedrock ofi+cxi -c "$RUN/bedrock-config.json" -v info > "$RUN/broker.log" 2>&1 &
BP=\$!
for _ in \$(seq 1 60); do [ -f "$RUN/mofka.json" ] && break; sleep 1; done
if [ -f "$RUN/mofka.json" ]; then
  source "$REPO/env/server.sh" --polaris >/dev/null 2>&1
  mofkactl topic create probe --groupfile "$RUN/mofka.json" >> "$RUN/broker.log" 2>&1
  mofkactl partition add probe --rank 0 --type memory --groupfile "$RUN/mofka.json" >> "$RUN/broker.log" 2>&1
  touch "$RUN/ready.flag"
fi
# hold the broker (and thus the step VNI) until the client signals done
for _ in \$(seq 1 90); do [ -f "$RUN/client.done" ] && break; sleep 1; done
kill \$BP 2>/dev/null; true
R0

# rank1 (N1): wait for broker ready, then attach over cxi and operate
cat > "$RUN/rank1.sh" <<R1
#!/bin/bash
cd "$RUN"
for _ in \$(seq 1 80); do [ -f "$RUN/ready.flag" ] && break; sleep 1; done
[ -f "$RUN/ready.flag" ] || { echo "client: broker never ready" > "$RUN/client.log"; touch "$RUN/client.done"; exit 3; }
source "$REPO/env/server.sh" --polaris >/dev/null 2>&1
echo "rank1 RAW VNIS=[\$SLINGSHOT_VNIS] host=\$(hostname -s)" >> "$RUN/client.log"
export SLINGSHOT_VNIS=\${SLINGSHOT_VNIS%%,*} SLINGSHOT_SVC_IDS=\${SLINGSHOT_SVC_IDS%%,*} SLINGSHOT_DEVICES=\${SLINGSHOT_DEVICES%%,*}
# attach from N1: list nothing exists, so create a 2nd topic as the cross-node fabric op
mofkactl topic create fromN1 --groupfile "$RUN/mofka.json" > "$RUN/client.log" 2>&1
rc=\$?
mofkactl partition add fromN1 --rank 0 --type memory --groupfile "$RUN/mofka.json" >> "$RUN/client.log" 2>&1
rc2=\$?
echo "client rc(topic)=\$rc rc(part)=\$rc2" >> "$RUN/client.log"
touch "$RUN/client.done"
exit \$(( rc || rc2 ))
R1
chmod +x "$RUN/rank0.sh" "$RUN/rank1.sh"

{
echo "nodes: N0=$N0  N1=$N1"; echo
echo "===== MPMD single step: bedrock@N0 : client@N1, ofi+cxi ====="
# single --single-node-vni step spanning both nodes via MPMD colon syntax -> shared step VNI
# PALS MPMD: --cpu-bind/--single-node-vni are GLOBAL; each section takes --hosts + -n + the cmd.
mpiexec --single-node-vni --cpu-bind none \
  --hosts "$N0" -n 1 "$RUN/rank0.sh" : \
  --hosts "$N1" -n 1 "$RUN/rank1.sh" \
  > "$RUN/mpmd.log" 2>&1
mrc=$?
echo "  mpmd step exit=$mrc"
echo "  broker addr: $(grep -oE 'ofi\+cxi://[^"]+' "$RUN/mofka.json" 2>/dev/null | head -1)"
echo "  -- client.log --"; sed 's/^/    /' "$RUN/client.log" 2>/dev/null | tail -10
echo "  -- mpmd.log tail --"; tail -8 "$RUN/mpmd.log" | sed 's/^/    /'
if grep -q 'rc(topic)=0 rc(part)=0' "$RUN/client.log" 2>/dev/null; then
    echo "  MPMD-CXI: PASS -- cross-node ofi+cxi attach works in a single MPMD step"
else
    echo "  MPMD-CXI: FAIL -- single step did not enable cross-node cxi attach"
fi
} >> "$RES" 2>&1
pkill -f 'bedrock ' 2>/dev/null
echo "=== DONE ==="; tail -6 "$RES"
