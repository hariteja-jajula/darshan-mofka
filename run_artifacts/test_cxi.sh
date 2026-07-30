#!/bin/bash
#PBS -A radix-io
#PBS -q debug
#PBS -l select=1:system=polaris
#PBS -l walltime=00:10:00
#PBS -l filesystems=home:eagle
#PBS -l place=scatter
#PBS -N cxi_selftest
# THROWAWAY. Proves server/start_server.sh brings up Mofka over ofi+cxi (T1 fix).
#   qsub run_artifacts/test_cxi.sh   ->   run_artifacts/CXI_TEST_RESULT (PASS|FAIL)
set -u
REPO="/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight"
RA="$REPO/run_artifacts"
RUN="$RA/cxitest"
RESULT="$RA/CXI_TEST_RESULT"

rm -rf "$RUN"; mkdir -p "$RUN"
rm -f "$RESULT"

cd "$REPO" || { echo "FAIL: no repo" > "$RESULT"; exit 1; }

MOFKA_PROTOCOL=ofi+cxi MOFKA_SERVER_DIR="$RUN" \
    bash server/start_server.sh --polaris > "$RUN/start.out" 2>&1

addr="$(grep -oE 'ofi\+cxi://[^"]+' "$RUN/mofka.json" 2>/dev/null | head -1)"
if [ -n "$addr" ]; then
    echo "PASS $addr" > "$RESULT"
else
    { echo "FAIL"; echo "--- start.out ---"; tail -30 "$RUN/start.out";
      echo "--- bedrock.log ---"; tail -40 "$RUN/bedrock.log" 2>/dev/null; } > "$RESULT"
fi

MOFKA_SERVER_DIR="$RUN" bash server/stop_server.sh >/dev/null 2>&1 || true
echo "=== DONE: $(head -1 "$RESULT") ==="
