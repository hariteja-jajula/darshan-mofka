#!/bin/bash
#PBS -A radix-io
#PBS -q debug
#PBS -l select=2:system=polaris
#PBS -l walltime=00:15:00
#PBS -l filesystems=home:eagle
#PBS -l place=scatter
#PBS -N gate0_mpi
# GATE-0 probe (amendment #1): can an MPI program run as an MPMD section next to a
# STRIPPED non-MPI bedrock section under ONE PALS launch? Governs ONLY the future
# MPI-IO workload branch -- the first-green path (C, io_bench) is non-MPI and unaffected.
#   A mpi_ctrl : plain cross-node 2-rank MPI hello, no bedrock. Confirms toolchain.
#   B mpi_vs_stripped_bedrock : bedrock(N0,-n1,STRIPPED) : mpi_hello(N1,-n2,UNSTRIPPED).
#     MPI_OK written -> MPI coexists (option c, free). timeout/no flag -> MPI_Init hangs (fork).
# Verdict from flag files only; mpiexec exit code is meaningless (timeout kills the broker).
# Writes run_artifacts/GATE0_MPI_RESULT.
set -u
REPO="/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight"
RA="$REPO/run_artifacts"; RUN="$RA/gate0mpi"; RES="$RA/GATE0_MPI_RESULT"
rm -rf "$RUN"; mkdir -p "$RUN"; : > "$RES"
cd "$REPO" || { echo "FAIL: no repo" >"$RES"; exit 1; }
source env/server.sh --polaris >/dev/null 2>&1
mapfile -t NODES < <(sort -u "$PBS_NODEFILE")
N0="${NODES[0]}"; N1="${NODES[1]}"
{ echo "nodes: N0=$N0  N1=$N1"; echo; } | tee -a "$RES"

# compile the MPI hello with the Cray wrapper
cc -O2 -o "$RUN/mpi_hello" "$RA/mpi_hello.c" 2> "$RUN/build.log"
if [ ! -x "$RUN/mpi_hello" ]; then
  echo "FAIL: mpi_hello did not build"; cat "$RUN/build.log"; echo "cc build failed" >> "$RES"; exit 1
fi | tee -a "$RES"

STRIP='for v in $(compgen -v | grep -E "^(PMI_|PMIX_|PALS_)"); do unset "$v"; done;'
COLL='export SLINGSHOT_VNIS=${SLINGSHOT_VNIS%%,*} SLINGSHOT_SVC_IDS=${SLINGSHOT_SVC_IDS%%,*} SLINGSHOT_DEVICES=${SLINGSHOT_DEVICES%%,*};'
cp server/bedrock-config.json "$RUN/bedrock-config.json"

# ---------- Config A: plain cross-node MPI hello (control) ----------
{ echo "===== A mpi_ctrl: mpiexec --hosts N0,N1 -n 2 mpi_hello (no bedrock) ====="; } | tee -a "$RES"
rm -f "$RUN/A_ok"
timeout 90 mpiexec --cpu-bind none --hosts "$N0,$N1" -n 2 "$RUN/mpi_hello" "$RUN/A_ok" > "$RUN/A.log" 2>&1
arc=$?
{
  echo "  exit=$arc  A_ok=$([ -f "$RUN/A_ok" ] && cat "$RUN/A_ok" || echo MISSING)"
  echo "  stderr:"; grep 'mpi_hello:' "$RUN/A.log" 2>/dev/null | sed 's/^/    /'
  if [ -f "$RUN/A_ok" ]; then echo "  VERDICT A: PASS -- cross-node MPI toolchain works"; else echo "  VERDICT A: FAIL"; fi
  echo
} | tee -a "$RES"

# ---------- Config B: stripped bedrock : unstripped MPI hello (THE test) ----------
cat > "$RUN/sB0.sh" <<S0
#!/bin/bash
cd "$RUN"; rm -f mofka.json
echo "sB0 bedrock start host=\$(hostname -s) PMI_SIZE=\${PMI_SIZE:-unset}" >&2
$STRIP
$COLL
source "$REPO/env/server.sh" --polaris >/dev/null 2>&1
echo "sB0 post-strip PMI_SIZE=\${PMI_SIZE:-unset}; launching bedrock" >&2
exec bedrock ofi+cxi -c "$RUN/bedrock-config.json" -v info > "$RUN/broker.log" 2>&1 < /dev/null
S0
cat > "$RUN/sB1.sh" <<S1
#!/bin/bash
cd "$RUN"
echo "sB1 mpi_hello start host=\$(hostname -s) PMI_RANK=\${PMI_RANK:-unset} PMI_SIZE=\${PMI_SIZE:-unset}" >&2
# NOT stripped: the MPI section keeps its PMI world so MPI_Init can fence.
$COLL
exec "$RUN/mpi_hello" "$RUN/B_ok"
S1
chmod +x "$RUN/sB0.sh" "$RUN/sB1.sh"

{ echo "===== B mpi_vs_stripped_bedrock: bedrock(N0,-n1,strip) : mpi_hello(N1,-n2,no-strip) ====="; } | tee -a "$RES"
rm -f "$RUN/B_ok"
timeout 110 mpiexec --cpu-bind none \
   --hosts "$N0" -n 1 "$RUN/sB0.sh" : \
   --hosts "$N1" -n 2 "$RUN/sB1.sh" > "$RUN/B.log" 2>&1
brc=$?
broker_up=no; grep -q 'Bedrock daemon now running at ofi+cxi' "$RUN/broker.log" 2>/dev/null && broker_up=yes
{
  echo "  exit=$brc  broker_up=$broker_up  B_ok=$([ -f "$RUN/B_ok" ] && cat "$RUN/B_ok" || echo MISSING)"
  echo "  hello stderr:"; grep 'mpi_hello:\|sB1' "$RUN/B.log" 2>/dev/null | sed 's/^/    /'
  echo "  broker.log tail:"; tail -3 "$RUN/broker.log" 2>/dev/null | sed 's/^/    /'
  if [ -f "$RUN/B_ok" ]; then
    echo "  VERDICT B: PASS -- MPI_Init COMPLETED beside a stripped bedrock section."
    echo "           => option (c): MPI-IO workload streams cross-node, no wrapper needed."
  else
    echo "  VERDICT B: HANG -- MPI_Init did not complete beside a stripped section."
    echo "           => FORK: (a) babysitter+comm-split (keep MPI workload) OR (b) non-MPI-only."
  fi
  echo
} | tee -a "$RES"

pkill -f "bedrock ofi+cxi" 2>/dev/null; sleep 2
echo "=== DONE ===" | tee -a "$RES"
tail -40 "$RES"
