#!/bin/bash
#PBS -A radix-io
#PBS -q debug
#PBS -l select=2:system=polaris
#PBS -l walltime=00:20:00
#PBS -l filesystems=home:eagle
#PBS -l place=scatter
#PBS -N mpmd_cxi2
# THROWAWAY probe v2: does cross-node ofi+cxi attach work in ONE MPMD mpiexec step,
# with bedrock as a NON-MPI (bootstrap:self) section?  Two fixes vs the prior MPMD probe
# (which failed at bring-up, broker.log empty -> attach never tested):
#   (1) exec bedrock DIRECTLY in its section (prior backgrounded it as a grandchild).
#   (2) test WITHOUT --single-node-vni: let PALS assign the normal multi-node JOB VNI that
#       spans both sections (how ordinary cross-node MPI uses CXI), vs WITH it, +/- collapse.
# Section0 (N0) = bedrock ofi+cxi (non-MPI). Section1 (N1) = client attaches via mofkactl RPCs.
# PASS if the client's cross-node topic-create + partition-add RPCs return rc=0.
# Writes run_artifacts/MPMD_CXI2_RESULT.
set -u
REPO="/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight"
RA="$REPO/run_artifacts"; BASE="$RA/mpmd2"; RES="$RA/MPMD_CXI2_RESULT"
rm -rf "$BASE"; mkdir -p "$BASE"; : > "$RES"
cd "$REPO" || { echo "FAIL: no repo" >"$RES"; exit 1; }
source env/server.sh --polaris >/dev/null 2>&1
mapfile -t NODES < <(sort -u "$PBS_NODEFILE")
N0="${NODES[0]}"; N1="${NODES[1]}"
{ echo "nodes: N0=$N0  N1=$N1"; echo; } | tee -a "$RES"

# run_cfg <tag> <snv:yes|no> <collapse:none|first|last>
run_cfg() {
  local tag="$1" snv="$2" collapse="$3"
  local RUN="$BASE/$tag"; mkdir -p "$RUN"
  cp server/bedrock-config.json "$RUN/bedrock-config.json"
  local COLL=""
  case "$collapse" in
    first) COLL='export SLINGSHOT_VNIS=${SLINGSHOT_VNIS%%,*} SLINGSHOT_SVC_IDS=${SLINGSHOT_SVC_IDS%%,*} SLINGSHOT_DEVICES=${SLINGSHOT_DEVICES%%,*};';;
    last)  COLL='export SLINGSHOT_VNIS=${SLINGSHOT_VNIS##*,} SLINGSHOT_SVC_IDS=${SLINGSHOT_SVC_IDS##*,} SLINGSHOT_DEVICES=${SLINGSHOT_DEVICES##*,};';;
  esac

  # --- section 0 (N0): bedrock, non-MPI, exec'd foreground, fully logged ---
  cat > "$RUN/s0.sh" <<S0
#!/bin/bash
cd "$RUN"; rm -f mofka.json
echo "s0 RAW VNIS=[\$SLINGSHOT_VNIS] host=\$(hostname -s)" >&2
$COLL
source "$REPO/env/server.sh" --polaris >/dev/null 2>&1
exec bedrock ofi+cxi -c "$RUN/bedrock-config.json" -v info > "$RUN/broker.log" 2>&1
S0

  # --- section 1 (N1): wait for groupfile on shared FS, attach over cxi via mofkactl ---
  cat > "$RUN/s1.sh" <<S1
#!/bin/bash
cd "$RUN"
echo "s1 RAW VNIS=[\$SLINGSHOT_VNIS] host=\$(hostname -s)" > "$RUN/client.log"
$COLL
source "$REPO/env/server.sh" --polaris >/dev/null 2>&1
for _ in \$(seq 1 45); do [ -f "$RUN/mofka.json" ] && break; sleep 1; done
if [ ! -f "$RUN/mofka.json" ]; then
  echo "client: broker never wrote mofka.json" >> "$RUN/client.log"
  echo "RC topic=NA part=NA" > "$RUN/client.rc"; exit 3
fi
mofkactl topic create t_$tag --groupfile "$RUN/mofka.json" >> "$RUN/client.log" 2>&1; rc1=\$?
mofkactl partition add t_$tag --rank 0 --type memory --groupfile "$RUN/mofka.json" >> "$RUN/client.log" 2>&1; rc2=\$?
echo "RC topic=\$rc1 part=\$rc2" > "$RUN/client.rc"
exit \$(( rc1 || rc2 ))
S1
  chmod +x "$RUN/s0.sh" "$RUN/s1.sh"

  local SNVFLAG=""; [ "$snv" = yes ] && SNVFLAG="--single-node-vni"
  { echo "===== CFG $tag: single-node-vni=$snv collapse=$collapse ====="; } | tee -a "$RES"
  timeout 130 mpiexec $SNVFLAG --cpu-bind none \
     --hosts "$N0" -n 1 "$RUN/s0.sh" : \
     --hosts "$N1" -n 1 "$RUN/s1.sh" > "$RUN/mpmd.log" 2>&1
  local mrc=$?
  {
    echo "  mpmd exit=$mrc  broker_addr=$(grep -oE 'ofi\+cxi://[^"]+' "$RUN/mofka.json" 2>/dev/null | head -1)"
    echo "  $(cat "$RUN/client.rc" 2>/dev/null || echo 'no client.rc')"
    echo "  broker.log tail:"; tail -4 "$RUN/broker.log" 2>/dev/null | sed 's/^/    /'
    echo "  client.log tail:"; tail -5 "$RUN/client.log" 2>/dev/null | sed 's/^/    /'
    if grep -q 'RC topic=0 part=0' "$RUN/client.rc" 2>/dev/null; then
      echo "  VERDICT $tag: PASS -- cross-node ofi+cxi attach works in one MPMD step"
    else
      echo "  VERDICT $tag: FAIL"
    fi
    echo
  } | tee -a "$RES"
  pkill -f 'bedrock ofi+cxi' 2>/dev/null; sleep 2; true
}

run_cfg nosnv_nocoll no  none
run_cfg nosnv_first  no  first
run_cfg snv_first    yes first
echo "=== DONE ===" | tee -a "$RES"
tail -30 "$RES"
