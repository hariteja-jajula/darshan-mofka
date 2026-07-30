#!/bin/bash
#PBS -A radix-io
#PBS -q debug
#PBS -l select=2:system=polaris
#PBS -l walltime=00:15:00
#PBS -l filesystems=home:eagle
#PBS -l place=scatter
#PBS -N mpmd_3sec
# THROWAWAY: extends the proven 2-section MPMD result to THREE roles in ONE mpiexec.
# s0=bedrock broker (N0, ofi+cxi), s1=consumer stand-in (N0, SAME node as broker),
# s2=workload/producer stand-in (N1, DIFFERENT node). Proves a same-node NON-broker section
# can attach the CXI broker AND a 3rd section does a cross-node RPC -- the real pipeline shape.
# Same PMI-strip + cxi collapse-to-first as mpmd_nopmi_probe.sh. Writes run_artifacts/MPMD_3SEC_RESULT.
set -u
REPO="/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight"
RA="$REPO/run_artifacts"; RUN="$RA/mpmd3sec"; RES="$RA/MPMD_3SEC_RESULT"
rm -rf "$RUN"; mkdir -p "$RUN"; : > "$RES"
cd "$REPO" || { echo "FAIL: no repo" >"$RES"; exit 1; }
source env/server.sh --polaris >/dev/null 2>&1
mapfile -t NODES < <(sort -u "$PBS_NODEFILE")
N0="${NODES[0]}"; N1="${NODES[1]}"
{ echo "nodes: N0=$N0  N1=$N1"; echo; } | tee -a "$RES"

cp server/bedrock-config.json "$RUN/bedrock-config.json"

# strip the phantom MPI world but KEEP SLINGSHOT_* (VNI); collapse cxi lists to first entry.
# Both emitted LITERALLY into each section (single-quoted here -> written verbatim to the .sh).
STRIP='for v in $(compgen -v | grep -E "^(PMI_|PMIX_|PALS_)"); do unset "$v"; done;'
COLL='export SLINGSHOT_VNIS=${SLINGSHOT_VNIS%%,*} SLINGSHOT_SVC_IDS=${SLINGSHOT_SVC_IDS%%,*} SLINGSHOT_DEVICES=${SLINGSHOT_DEVICES%%,*};'

# ---- Section 0: bedrock broker on N0 (ofi+cxi) --------------------------------
cat > "$RUN/s0.sh" <<S0
#!/bin/bash
cd "$RUN"; rm -f mofka.json
echo "s0 MARK start host=\$(hostname -s) VNIS=[\$SLINGSHOT_VNIS] PMI_SIZE=\${PMI_SIZE:-unset}" >&2
$STRIP
$COLL
source "$REPO/env/server.sh" --polaris >/dev/null 2>&1
echo "s0 MARK post-strip host=\$(hostname -s) PMI_SIZE=\${PMI_SIZE:-unset} VNIS=[\$SLINGSHOT_VNIS]; launching bedrock (ofi+cxi)" >&2
exec bedrock ofi+cxi -c "$RUN/bedrock-config.json" -v info > "$RUN/broker.log" 2>&1 < /dev/null
S0

# ---- Section 1: consumer stand-in on N0 (SAME node as broker) -----------------
cat > "$RUN/s1.sh" <<S1
#!/bin/bash
cd "$RUN"
echo "s1 MARK start host=\$(hostname -s) PMI_SIZE=\${PMI_SIZE:-unset} VNIS=[\$SLINGSHOT_VNIS]" >&2
echo "s1 (consumer) start host=\$(hostname -s)" > "$RUN/consumer.log"
$STRIP
$COLL
source "$REPO/env/server.sh" --polaris >/dev/null 2>&1
echo "s1 MARK post-strip host=\$(hostname -s) PMI_SIZE=\${PMI_SIZE:-unset} VNIS=[\$SLINGSHOT_VNIS]" >&2
for _ in \$(seq 1 40); do [ -f "$RUN/mofka.json" ] && break; sleep 1; done
if [ ! -f "$RUN/mofka.json" ]; then
  echo "consumer: broker never wrote mofka.json" >> "$RUN/consumer.log"
  echo "RC topic=NA part=NA" > "$RUN/consumer.rc"
  touch "$RUN/CONSUMER_READY"
  exit 3
fi
echo "consumer: mofka.json seen -> attaching CXI broker from SAME node" >> "$RUN/consumer.log"
mofkactl topic create t_probe --groupfile "$RUN/mofka.json" >> "$RUN/consumer.log" 2>&1; rc1=\$?
mofkactl partition add t_probe --rank 0 --type memory --groupfile "$RUN/mofka.json" >> "$RUN/consumer.log" 2>&1; rc2=\$?
echo "RC topic=\$rc1 part=\$rc2" > "$RUN/consumer.rc"
touch "$RUN/CONSUMER_READY"
exit \$(( rc1 || rc2 ))
S1

# ---- Section 2: workload/producer stand-in on N1 (DIFFERENT node) -------------
cat > "$RUN/s2.sh" <<S2
#!/bin/bash
cd "$RUN"
echo "s2 MARK start host=\$(hostname -s) PMI_SIZE=\${PMI_SIZE:-unset} VNIS=[\$SLINGSHOT_VNIS]" >&2
echo "s2 (workload) start host=\$(hostname -s)" > "$RUN/workload.log"
$STRIP
$COLL
source "$REPO/env/server.sh" --polaris >/dev/null 2>&1
echo "s2 MARK post-strip host=\$(hostname -s) PMI_SIZE=\${PMI_SIZE:-unset} VNIS=[\$SLINGSHOT_VNIS]" >&2
for _ in \$(seq 1 90); do [ -f "$RUN/CONSUMER_READY" ] && break; sleep 1; done
if [ ! -f "$RUN/CONSUMER_READY" ]; then
  echo "workload: CONSUMER_READY never appeared" >> "$RUN/workload.log"
  echo "RC list=NA create=NA" > "$RUN/workload.rc"
  exit 3
fi
echo "workload: CONSUMER_READY seen -> cross-node RPC from 3rd section (N1)" >> "$RUN/workload.log"
mofkactl topic list --groupfile "$RUN/mofka.json" >> "$RUN/workload.log" 2>&1; rc1=\$?
mofkactl topic create t_probe_wl --groupfile "$RUN/mofka.json" >> "$RUN/workload.log" 2>&1; rc2=\$?
echo "RC list=\$rc1 create=\$rc2" > "$RUN/workload.rc"
exit \$(( rc1 || rc2 ))
S2

chmod +x "$RUN/s0.sh" "$RUN/s1.sh" "$RUN/s2.sh"

# ---- ONE mpiexec, THREE colon-separated sections: N0:s0  N0:s1  N1:s2 ---------
{ echo "===== 3-SECTION MPMD: s0=broker(N0) s1=consumer(N0) s2=workload(N1), ofi+cxi (PMI stripped) ====="; } | tee -a "$RES"
timeout 120 mpiexec --cpu-bind none \
   --hosts "$N0" -n 1 "$RUN/s0.sh" : \
   --hosts "$N0" -n 1 "$RUN/s1.sh" : \
   --hosts "$N1" -n 1 "$RUN/s2.sh" > "$RUN/mpmd.log" 2>&1
mrc=$?

broker_up=no
grep -q 'Bedrock daemon now running at ofi+cxi' "$RUN/broker.log" 2>/dev/null && broker_up=yes
consumer_ok=no
grep -q 'RC topic=0 part=0' "$RUN/consumer.rc" 2>/dev/null && consumer_ok=yes
workload_ok=no
grep -q 'RC list=0 create=0' "$RUN/workload.rc" 2>/dev/null && workload_ok=yes

{
  echo "  mpmd exit=$mrc  broker_up=$broker_up  mofka.json=$([ -f "$RUN/mofka.json" ] && echo yes || echo no)  CONSUMER_READY=$([ -f "$RUN/CONSUMER_READY" ] && echo yes || echo no)"
  echo "  markers:"; grep 'MARK' "$RUN/mpmd.log" 2>/dev/null | sed 's/^/    /'
  echo "  broker.log tail:"; tail -5 "$RUN/broker.log" 2>/dev/null | sed 's/^/    /'
  echo "  consumer(N0, same node): $(cat "$RUN/consumer.rc" 2>/dev/null || echo 'no consumer.rc')"
  echo "  consumer.log tail:"; tail -4 "$RUN/consumer.log" 2>/dev/null | sed 's/^/    /'
  echo "  workload(N1, cross-node): $(cat "$RUN/workload.rc" 2>/dev/null || echo 'no workload.rc')"
  echo "  workload.log tail:"; tail -4 "$RUN/workload.log" 2>/dev/null | sed 's/^/    /'
  echo
  if [ "$broker_up" = yes ] && [ "$consumer_ok" = yes ] && [ "$workload_ok" = yes ]; then
    echo "VERDICT 3sec: PASS -- broker up (ofi+cxi) + same-node consumer attached + cross-node workload RPC worked, all in ONE mpiexec"
  else
    echo "VERDICT 3sec: FAIL -- broker_up=$broker_up consumer_ok=$consumer_ok workload_ok=$workload_ok"
  fi
} | tee -a "$RES"

pkill -f "bedrock ofi+cxi" 2>/dev/null; sleep 2
echo "=== DONE ===" | tee -a "$RES"
tail -40 "$RES"
