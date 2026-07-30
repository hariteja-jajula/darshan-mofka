#!/bin/bash
#PBS -A radix-io
#PBS -q debug
#PBS -l select=2:system=polaris
#PBS -l walltime=00:15:00
#PBS -l filesystems=home:eagle
#PBS -l place=scatter
#PBS -N mpmd_diag
# THROWAWAY diag: WHY does bedrock produce a 0-byte log as an MPMD section?
# v2 showed all 3 VNI configs fail identically at bedrock BRING-UP (broker.log empty),
# not at attach. Separate the two candidate causes:
#   (A) MPMD/PMI structurally hangs a non-MPI (bootstrap:self) section -> transport-independent.
#   (B) ofi+cxi init specifically hangs in this context -> transport-dependent.
# Method: run bedrock as an MPMD section over TCP (control) and over CXI, with STDERR
# progress markers to localize the hang (after source? after exec? bedrock silent?).
# Client attaches cross-node with matching transport via mofkactl RPCs.
# Writes run_artifacts/MPMD_DIAG_RESULT.
set -u
REPO="/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight"
RA="$REPO/run_artifacts"; BASE="$RA/mpmddiag"; RES="$RA/MPMD_DIAG_RESULT"
rm -rf "$BASE"; mkdir -p "$BASE"; : > "$RES"
cd "$REPO" || { echo "FAIL: no repo" >"$RES"; exit 1; }
source env/server.sh --polaris >/dev/null 2>&1
mapfile -t NODES < <(sort -u "$PBS_NODEFILE")
N0="${NODES[0]}"; N1="${NODES[1]}"
{ echo "nodes: N0=$N0  N1=$N1"; echo; } | tee -a "$RES"

# run_cfg <tag> <proto> <collapse:none|first>
run_cfg() {
  local tag="$1" proto="$2" collapse="$3"
  local RUN="$BASE/$tag"; mkdir -p "$RUN"
  cp server/bedrock-config.json "$RUN/bedrock-config.json"
  local COLL=""
  [ "$collapse" = first ] && COLL='export SLINGSHOT_VNIS=${SLINGSHOT_VNIS%%,*} SLINGSHOT_SVC_IDS=${SLINGSHOT_SVC_IDS%%,*} SLINGSHOT_DEVICES=${SLINGSHOT_DEVICES%%,*};'

  # section 0 (N0): bedrock with progress markers to stderr (-> mpmd.log)
  cat > "$RUN/s0.sh" <<S0
#!/bin/bash
cd "$RUN"; rm -f mofka.json
echo "s0 MARK start host=\$(hostname -s) RAW_VNIS=[\$SLINGSHOT_VNIS] PMI_RANK=\${PMI_RANK:-unset} PMI_SIZE=\${PMI_SIZE:-unset} PALS_RANKID=\${PALS_RANKID:-unset}" >&2
$COLL
source "$REPO/env/server.sh" --polaris >/dev/null 2>&1
echo "s0 MARK sourced; bedrock=\$(command -v bedrock)" >&2
echo "s0 MARK launching bedrock ($proto)" >&2
exec bedrock $proto -c "$RUN/bedrock-config.json" -v trace > "$RUN/broker.log" 2>&1
S0

  # section 1 (N1): wait for groupfile, attach via mofkactl RPCs (same transport, from group file)
  cat > "$RUN/s1.sh" <<S1
#!/bin/bash
cd "$RUN"
echo "s1 MARK start host=\$(hostname -s) PMI_RANK=\${PMI_RANK:-unset}" > "$RUN/client.log"
$COLL
source "$REPO/env/server.sh" --polaris >/dev/null 2>&1
for _ in \$(seq 1 40); do [ -f "$RUN/mofka.json" ] && break; sleep 1; done
if [ ! -f "$RUN/mofka.json" ]; then
  echo "client: broker never wrote mofka.json" >> "$RUN/client.log"
  echo "RC topic=NA part=NA" > "$RUN/client.rc"; exit 3
fi
echo "client: mofka.json seen, attaching" >> "$RUN/client.log"
mofkactl topic create t_$tag --groupfile "$RUN/mofka.json" >> "$RUN/client.log" 2>&1; rc1=\$?
mofkactl partition add t_$tag --rank 0 --type memory --groupfile "$RUN/mofka.json" >> "$RUN/client.log" 2>&1; rc2=\$?
echo "RC topic=\$rc1 part=\$rc2" > "$RUN/client.rc"
exit \$(( rc1 || rc2 ))
S1
  chmod +x "$RUN/s0.sh" "$RUN/s1.sh"

  { echo "===== CFG $tag: proto=$proto collapse=$collapse ====="; } | tee -a "$RES"
  timeout 110 mpiexec --cpu-bind none \
     --hosts "$N0" -n 1 "$RUN/s0.sh" : \
     --hosts "$N1" -n 1 "$RUN/s1.sh" > "$RUN/mpmd.log" 2>&1
  local mrc=$?
  {
    echo "  mpmd exit=$mrc  broker.log_bytes=$(wc -c < "$RUN/broker.log" 2>/dev/null)  mofka.json=$([ -f "$RUN/mofka.json" ] && echo yes || echo no)"
    echo "  markers (mpmd.log):"; grep 'MARK' "$RUN/mpmd.log" 2>/dev/null | sed 's/^/    /'
    echo "  broker.log tail:"; tail -6 "$RUN/broker.log" 2>/dev/null | sed 's/^/    /'
    echo "  $(cat "$RUN/client.rc" 2>/dev/null || echo 'no client.rc')"
    echo "  client.log tail:"; tail -4 "$RUN/client.log" 2>/dev/null | sed 's/^/    /'
    if grep -q 'RC topic=0 part=0' "$RUN/client.rc" 2>/dev/null; then
      echo "  VERDICT $tag: PASS -- cross-node $proto attach works in one MPMD step"
    else
      echo "  VERDICT $tag: FAIL"
    fi
    echo
  } | tee -a "$RES"
  pkill -f "bedrock $proto" 2>/dev/null; sleep 2; true
}

run_cfg tcp_ctrl  ofi+tcp none
run_cfg cxi_first ofi+cxi first
echo "=== DONE ===" | tee -a "$RES"
tail -40 "$RES"
