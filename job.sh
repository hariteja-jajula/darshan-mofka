#!/bin/bash
# job.sh -- ONE-SHOT MPIIO validation run (temporary; delete once validated).
#
# Run this on a Polaris COMPUTE node (grab one via qsub -I first), from the repo
# root:
#     qsub -I -q debug -A radix-io -l select=1 -l walltime=01:00:00 -l filesystems=home:eagle
#     cd /eagle/radix-io/hjajula/test/darshan-mofka
#     bash job.sh
#     python3 analysis.py
#
# It follows the README end-to-end but targets the MPI-IO workload so the MPIIO
# close-streaming fix is exercised:
#   build diaspora (if needed) -> build DARSHAN_MPI runtime -> build util ->
#   build MPIIO workload -> fresh broker -> FlowCept consumer ->
#   mpiexec -n 4 workload under LD_PRELOAD -> export MongoDB -> JSONL ->
#   reconstruct a partial .darshan.
#
# All artifacts land under $OUT (printed at the end) for analysis.py to read.
# Nothing here is committed long-term: this is a scratch harness.
set -uo pipefail

# ---------------------------------------------------------------------------
# 0. config
# ---------------------------------------------------------------------------
NRANKS="${NRANKS:-4}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
OUT="$ROOT/_mpiio_validation"           # everything this run produces
rm -rf "$OUT"; mkdir -p "$OUT"
EVENTS="$OUT/events.jsonl"
RECON="$OUT/job_partial.darshan"
export MPIIO_OUT="$OUT"                  # analysis.py reads this to find artifacts

say() { printf '\n########## %s ##########\n' "$*"; }
die() { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. environment + Polaris pkg-config fix (README steps 1-3 notes)
# ---------------------------------------------------------------------------
say "1. environment"
# shellcheck disable=SC1091
source server/env.sh --polaris || die "could not source server/env.sh --polaris"
module unload darshan 2>/dev/null || true
# strip the system darshan pkg-config hook that breaks the Cray cc compiler check
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH#/soft/perftools/darshan/darshan-3.4.4/lib/pkgconfig:}"
pkg-config --exists zlib && echo "zlib OK" || echo "WARN: zlib not visible to pkg-config"

echo "ROOT=$ROOT"
echo "MOFKA_SPACK_VIEW=$MOFKA_SPACK_VIEW"
echo "DIASPORA_C=$DIASPORA_C"
echo "CC=$CC"
echo "PY=$PY"

# ---------------------------------------------------------------------------
# 2. build diaspora-stream-api  (README step 2 -- always build, then re-source)
# ---------------------------------------------------------------------------
say "2. diaspora-stream-api"
( cd diaspora-stream-api \
  && cmake -S . -B _build -DENABLE_C_API=ON -DENABLE_PYTHON=ON \
        -DCMAKE_PREFIX_PATH="$MOFKA_SPACK_VIEW" \
        -DCMAKE_INSTALL_PREFIX="$PWD/install" \
  && cmake --build _build -j \
  && cmake --install _build ) || die "diaspora build failed"

# README step 2: re-source env AFTER installing diaspora so its python
# site-packages (pydiaspora_stream_api) land on PYTHONPATH for the consumer,
# then re-apply the Polaris pkg-config fix (re-sourcing re-adds the bad path).
# shellcheck disable=SC1091
source server/env.sh --polaris
module unload darshan 2>/dev/null || true
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH#/soft/perftools/darshan/darshan-3.4.4/lib/pkgconfig:}"

say "2b. verify diaspora + mofka python imports (README step 2)"
"$PY" - <<'PY' || die "python cannot import pydiaspora_stream_api / mochi.mofka -- check PYTHONPATH"
import pydiaspora_stream_api
import mochi.mofka.client
print("mochi.mofka import OK")
PY

# ---------------------------------------------------------------------------
# 3. build the MPI Darshan runtime (the whole point) + util + workload
# ---------------------------------------------------------------------------
say "3a. Darshan MPI runtime (DARSHAN_MPI=1)"
# DIASPORA_C must resolve to a real install; if empty/missing, MOFKA_CFLAGS will
# be empty and darshan-mofka.c won't find diaspora/diaspora_c.h.
echo "DIASPORA_C=$DIASPORA_C"
[[ -f "$DIASPORA_C/include/diaspora/diaspora_c.h" ]] \
    || die "DIASPORA_C invalid: no include/diaspora/diaspora_c.h under '$DIASPORA_C' (build diaspora first)"
# Wipe any stale _build-mpi: build.sh only re-wipes on srcdir mismatch, so a tree
# configured from a PRE-fix Makefile.in gets reused and the static-lib Mofka
# include fix (commit e9d860c1) never takes -> 'diaspora/diaspora_c.h not found'.
rm -rf darshan/_build-mpi
# BULLETPROOF FIX for "diaspora/diaspora_c.h: No such file" on the STATIC lib:
# the per-target libdarshan_a_CPPFLAGS += $(MOFKA_CFLAGS) fix can be lost when
# Polaris' maintainer-mode automake regenerates lib/Makefile.in. configure feeds
# $CPPFLAGS to EVERY compile (both shared and static libs), so put the diaspora
# include there directly -- independent of any per-target Makefile wiring.
export CPPFLAGS="-I$DIASPORA_C/include ${CPPFLAGS:-}"
echo "CPPFLAGS=$CPPFLAGS"
# Polaris' Cray cc wrapper is MPI-aware, so pin CC/CXX to it (build.sh would
# otherwise reach for mpicc, which isn't the Cray wrapper here).
( cd darshan && DARSHAN_MPI=1 CC="$CC" CXX="${CXX:-CC}" ./build.sh ) \
    || die "Darshan MPI build failed"
export DARSHAN_PREFIX="$ROOT/darshan/install-mpi"
LIB="$(darshan_lib)"
echo "DARSHAN_PREFIX=$DARSHAN_PREFIX"
echo "darshan_lib=$LIB"
[[ -e "$LIB" ]] || die "libdarshan.so missing under install-mpi"

say "3b. confirm MPI wrappers are present in the lib"
if nm -D "$LIB" | grep -Eq "MPI_File_open|PMPI_File_open"; then
    echo "MPI wrappers PRESENT (good):"
    nm -D "$LIB" | grep -E "MPI_File_open|PMPI_File_open|mpiio_runtime" | head
else
    echo "MPI wrappers MISSING in $LIB"
    die "lib is not MPI-enabled -- MPIIO records would be zero; aborting"
fi

say "3c. darshan-util (parser/reconstruct)"
( cd darshan/darshan-util
  if [[ ! -f _build_util/Makefile ]]; then
      ( cd .. && ./prepare.sh )
      mkdir -p _build_util
      ( cd _build_util && ../configure --prefix="$PWD/../install" )
  fi
  ( cd _build_util && make -j4 && make install ) ) || die "darshan-util build failed"
B="$ROOT/darshan/darshan-util/install/bin"
[[ -x "$B/darshan-parser" ]] || die "darshan-parser not built at $B"
[[ -x "$B/darshan-mofka-reconstruct" ]] || die "darshan-mofka-reconstruct not built at $B"

say "3d. build MPIIO workload"
"$CC" -O2 workloads/mofka_forward_mpiio.c -o workloads/mofka_forward_mpiio \
    || die "mpiio workload compile failed"

# ---------------------------------------------------------------------------
# 4. fresh broker (stale-topic bug: ALWAYS start clean)
# ---------------------------------------------------------------------------
say "4. fresh Mofka broker"
pkill -f capture.py 2>/dev/null || true
bash server/stop-server.sh >/dev/null 2>&1 || true
sleep 2
bash server/start-server.sh || die "start-server.sh failed"
GROUP="$ROOT/server/mofka.json"
[[ -s "$GROUP" ]] || die "no mofka.json after start-server.sh (see server/bedrock.log)"
cat "$GROUP"
trap 'bash server/stop-server.sh >/dev/null 2>&1 || true' EXIT

# ---------------------------------------------------------------------------
# 5. live FlowCept consumer
# ---------------------------------------------------------------------------
say "5. FlowCept consumer"
MONGOD="${MONGOD:-$(command -v mongod || true)}"
[[ -x "$MONGOD" ]] || die "mongod not found; set MONGOD=/path/to/mongod (README step 6)"
RUN_DIR="$OUT/flowcept"; mkdir -p "$RUN_DIR"
RUN_DIR="$RUN_DIR" MONGO_DB=darshan_stream MONGO_PORT=27017 MONGOD="$MONGOD" \
MOFKA_GROUP="$GROUP" bash server/capture_flowcept.sh > "$RUN_DIR/flowcept.out" 2>&1 &
FC=$!
until grep -q 'consumer alive' "$RUN_DIR/flowcept.out"; do
    kill -0 "$FC" 2>/dev/null || { echo "consumer failed to start:"; cat "$RUN_DIR/flowcept.out"; die "consumer startup"; }
    sleep 1
done
echo "consumer alive"

# ---------------------------------------------------------------------------
# 6. run the MPI-IO workload (NO DARSHAN_ENABLE_NONMPI: this is a real MPI job)
# ---------------------------------------------------------------------------
say "6. mpiexec -n $NRANKS mofka_forward_mpiio"
darshan_ensure_logdir >/dev/null
mpiexec -n "$NRANKS" env \
    DARSHAN_MOFKA_ENABLE=1 \
    DARSHAN_MOFKA_GROUP_FILE="$GROUP" \
    DARSHAN_MOFKA_TOPIC=darshan \
    DARSHAN_MOFKA_TIMING=1 \
    DARSHAN_MOFKA_FLUSH_MS=10000 \
    DARSHAN_LOGPATH="$DARSHAN_LOGPATH" \
    LD_PRELOAD="$LIB" \
    ./workloads/mofka_forward_mpiio "$OUT/mofka-forward-mpiio" \
    > "$OUT/mpiio.out" 2> "$OUT/mpiio.err"
echo "--- workload stdout ---"; cat "$OUT/mpiio.out"
SENDS="$(grep -c 'darshan-mofka\[timing\] send' "$OUT/mpiio.err" || true)"
echo "workload sends (timing lines): $SENDS"
[[ "$SENDS" -gt 0 ]] || echo "WARN: 0 sends -- MPIIO path may not have fired (check lib is MPI-enabled)"

# ---------------------------------------------------------------------------
# 7. stop consumer (flush), export MongoDB -> JSONL
# ---------------------------------------------------------------------------
say "7. flush + export"
touch "$RUN_DIR/SHUTDOWN"
until grep -q 'Export now' "$RUN_DIR/flowcept.out"; do
    kill -0 "$FC" 2>/dev/null || { echo "consumer died before export:"; tail -40 "$RUN_DIR/flowcept.out"; die "consumer"; }
    sleep 1
done
"$PY" server/export_jsonl.py 127.0.0.1 darshan_stream > "$EVENTS" 2> "$OUT/export.count"
kill "$FC" 2>/dev/null || true; wait "$FC" 2>/dev/null || true
echo "exported JSONL: $EVENTS  ($(wc -l < "$EVENTS") lines)"
cat "$OUT/export.count" || true
echo "--- FlowCept ingest verdict ---"
grep -E 'INGEST:|tasks total=' "$RUN_DIR/flowcept.out" || true

# ---------------------------------------------------------------------------
# 8. reconstruct a partial darshan log from the stream
# ---------------------------------------------------------------------------
say "8. reconstruct partial darshan log"
rm -f "$RECON"
"$B/darshan-mofka-reconstruct" "$EVENTS" "$RECON" || echo "WARN: reconstruct returned nonzero"
if [[ -e "$RECON" ]]; then
    echo "--- darshan-parser (MPIIO/POSIX/STDIO records) ---"
    "$B/darshan-parser" --show-incomplete "$RECON" \
        | grep -E "^(MPIIO|POSIX|STDIO)" | head -60 || true
fi

# record the util bin path so analysis.py can reuse the same parser
echo "$B" > "$OUT/util_bin_path"

say "DONE"
echo "Artifacts under: $OUT"
echo "Next: python3 analysis.py"
