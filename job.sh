#!/bin/bash
# job.sh -- one-shot end-to-end run of the Darshan -> Mofka -> FlowCept -> MongoDB
# pipeline, then reconstruct a partial .darshan log from the stream and compare it
# 1:1 to the native log. Writes every artifact into results/<workload>_<ts>/.
#
# Run on a COMPUTE node from the repo root (the broker's fabric transport does not
# come up on login nodes):
#     qsub -A <project> -q debug -l select=1:ncpus=32 -l walltime=00:30:00 job.sh
#     # or interactively:  cd <repo> && bash job.sh [WORKLOAD]
#
# WORKLOAD (arg or $WORKLOAD): c (default) | mpi | dlio | python-ml
# Other knobs:
#   SKIP_BUILD=1   reuse an existing darshan/diaspora/util build
#   MONGOD=/path   override mongod (else env resolves Database/, server/, or PATH)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$ROOT"
SKIP_BUILD="${SKIP_BUILD:-0}"
WORKLOAD="${1:-${WORKLOAD:-c}}"

say()  { printf '\n########## %s ##########\n' "$*"; }
die()  { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. environment (server: broker/consumer/mongod/PY ; workload: CC/darshan)
# ---------------------------------------------------------------------------
say "1. environment (workload=$WORKLOAD)"
export TERM="${TERM:-xterm}"
# shellcheck disable=SC1091
source env/server.sh   || die "could not source env/server.sh"
# shellcheck disable=SC1091
source env/workload.sh || die "could not source env/workload.sh"
module unload darshan 2>/dev/null || true          # never the system darshan
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
darshan_ensure_logdir >/dev/null
echo "profile=$ENV_PROFILE  ROOT=$ROOT"
echo "MOFKA_SPACK_VIEW=$MOFKA_SPACK_VIEW"
echo "DIASPORA_C=$DIASPORA_C  DARSHAN_PREFIX=$DARSHAN_PREFIX"
echo "CC=$CC  PY=$PY  MONGOD=${MONGOD:-<unresolved>}"

# ---------------------------------------------------------------------------
# 2. build darshan (Mofka connector) + darshan-util + workload binary
# ---------------------------------------------------------------------------
if [[ "$SKIP_BUILD" = "1" && -e "$(darshan_lib 2>/dev/null)" ]]; then
    say "2. build (SKIP_BUILD=1, using $(darshan_lib))"
else
    if [[ ! -e "diaspora-stream-api/install/include/diaspora/diaspora_c.h" ]]; then
        say "2a. build diaspora-stream-api"
        ( cd diaspora-stream-api \
          && cmake -S . -B _build -DENABLE_C_API=ON -DENABLE_PYTHON=ON \
                -DCMAKE_PREFIX_PATH="$MOFKA_SPACK_VIEW" -DCMAKE_INSTALL_PREFIX="$PWD/install" \
          && cmake --build _build -j && cmake --install _build ) || die "diaspora build failed"
    fi
    say "2b. build darshan runtime (Mofka connector, non-MPI)"
    ./build.sh || die "darshan build failed"
    [[ -e "$(darshan_lib)" ]] || die "libdarshan.so missing after build"
    say "2c. build darshan-util (parser + reconstruct)"
    ( cd darshan/darshan-util
      if [[ ! -f _build_util/Makefile ]]; then
          ( cd .. && ./prepare.sh ); mkdir -p _build_util
          ( cd _build_util && ../configure --prefix="$PWD/../install" )
      fi
      ( cd _build_util && make -j4 && make install ) ) || die "darshan-util build failed"
fi
B="$ROOT/darshan/darshan-util/install/bin"
[[ -x "$B/darshan-parser" && -x "$B/darshan-mofka-reconstruct" ]] \
    || die "darshan-util tools missing at $B (run without SKIP_BUILD)"

# ---------------------------------------------------------------------------
# 3. mongod
# ---------------------------------------------------------------------------
say "3. mongod"
MONGOD="${MONGOD:-$(command -v mongod || true)}"
[[ -x "$MONGOD" ]] || die "mongod not found; run Database/get_mongod.sh or set MONGOD=/path/to/mongod"
echo "MONGOD=$MONGOD  ($("$MONGOD" --version | head -1))"

# ---------------------------------------------------------------------------
# 4. fresh broker + darshan topic
# ---------------------------------------------------------------------------
say "4. fresh Mofka broker"
bash server/stop_server.sh >/dev/null 2>&1 || true
sleep 2
bash server/start_server.sh || die "start_server.sh failed"
GROUP="$ROOT/server/mofka.json"
[[ -s "$GROUP" ]] || die "no mofka.json after start_server.sh"
trap 'bash server/stop_server.sh >/dev/null 2>&1 || true' EXIT

# ---------------------------------------------------------------------------
# 5. results dir + live FlowCept consumer (drains topic -> MongoDB)
# ---------------------------------------------------------------------------
RES="$ROOT/results/${WORKLOAD}_$(date +%Y%m%d_%H%M%S)"; mkdir -p "$RES"
say "5. FlowCept consumer  (results -> $RES)"
RUN_DIR="$ROOT/server/_flowcept_run"; rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR"
MONGO_DB=darshan_stream; MONGO_PORT=27017
EVENTS="$RES/events.jsonl"
RUN_DIR="$RUN_DIR" MONGO_DB="$MONGO_DB" MONGO_PORT="$MONGO_PORT" MONGOD="$MONGOD" \
MOFKA_GROUP="$GROUP" bash Client/capture_flowcept.sh > "$RUN_DIR/flowcept.out" 2>&1 &
FC=$!
until grep -q 'consumer alive' "$RUN_DIR/flowcept.out"; do
    kill -0 "$FC" 2>/dev/null || { cat "$RUN_DIR/flowcept.out"; die "consumer failed to start"; }
    sleep 1
done
echo "consumer alive (pid $FC)"

# ---------------------------------------------------------------------------
# 6. run the selected workload under the Darshan -> Mofka connector
# ---------------------------------------------------------------------------
say "6. run workload: $WORKLOAD"
run_instrumented() {   # run_instrumented <extra env-assignments...> -- <cmd...>
    local pre=(); while [[ "$1" != "--" ]]; do pre+=("$1"); shift; done; shift
    env DARSHAN_MOFKA_ENABLE=1 DARSHAN_MOFKA_GROUP_FILE="$GROUP" DARSHAN_MOFKA_TOPIC=darshan \
        DARSHAN_MOFKA_BATCH=0 DARSHAN_MOFKA_MAX_BATCHES=64 DARSHAN_MOFKA_TIMING=1 \
        DARSHAN_LOGPATH="$DARSHAN_LOGPATH" LD_PRELOAD="$(darshan_lib)" \
        "${pre[@]}" "$@"
}
NATIVE_GLOB="*.darshan"
case "$WORKLOAD" in
    c)
        "$CC" -O2 workloads/c/mofka_forward_smoke.c -o workloads/c/mofka_forward_smoke || die "compile failed"
        run_instrumented DARSHAN_ENABLE_NONMPI=1 -- \
            ./workloads/c/mofka_forward_smoke /tmp/mofka-forward-smoke \
            > "$RES/workload.out" 2> "$RES/workload.err"
        NATIVE_GLOB="*mofka_forward_smoke*.darshan" ;;
    mpi)
        DARSHAN_MPI=1 ./build.sh || die "MPI darshan build failed"
        MPICC="$(command -v mpicc || echo "$CC")"   # MPI-IO needs the MPI compiler wrapper
        "$MPICC" -O2 workloads/mpi/mofka_forward_mpiio.c -o workloads/mpi/mofka_forward_mpiio || die "compile failed"
        # env (incl. LD_PRELOAD) goes INSIDE mpiexec so only the ranks are
        # instrumented -- preloading the launcher (prterun) crashes it.
        # This node's Yama ptrace setting blocks cross-memory-attach shared memory,
        # which crashes openmpi's shared-memory transport at MPI_Init under the
        # Darshan preload. Force TCP-only (no shared memory) and oversubscribe one node.
        mpiexec --oversubscribe -n 4 --mca pml ob1 --mca btl tcp,self \
            env DARSHAN_MOFKA_ENABLE=1 DARSHAN_MOFKA_GROUP_FILE="$GROUP" DARSHAN_MOFKA_TOPIC=darshan \
            DARSHAN_MOFKA_BATCH=0 DARSHAN_MOFKA_MAX_BATCHES=64 DARSHAN_MOFKA_TIMING=1 \
            DARSHAN_MOFKA_FLUSH_MS=10000 DARSHAN_LOGPATH="$DARSHAN_LOGPATH" \
            LD_PRELOAD="$ROOT/darshan/install-mpi/lib/libdarshan.so" \
            ./workloads/mpi/mofka_forward_mpiio /tmp/mofka-forward-mpiio \
            > "$RES/workload.out" 2> "$RES/workload.err" || die "mpi workload failed"
        NATIVE_GLOB="*mofka_forward_mpiio*.darshan" ;;
    dlio)
        run_instrumented env -u PYTHONPATH -u PYTHONSAFEPATH -u PYTHONHOME -- \
            dlio_benchmark ++workload.workflow.generate_data=True ++workload.workflow.train=True \
            ++workload.dataset.data_folder="$RES/dlio_data" ++workload.dataset.num_files_train=8 \
            ++workload.dataset.num_samples_per_file=1 ++workload.dataset.record_length_bytes=1024 \
            ++workload.reader.batch_size=2 ++workload.reader.read_threads=1 \
            ++workload.train.epochs=1 ++workload.train.computation_time=0.01 \
            hydra.run.dir="$RES/dlio" > "$RES/workload.out" 2> "$RES/workload.err" || die "dlio failed" ;;
    python-ml)
        run_instrumented DARSHAN_ENABLE_NONMPI=1 -- \
            "$PY" workloads/python-ml/train.py "$RES/mldata" \
            > "$RES/workload.out" 2> "$RES/workload.err" || die "python-ml failed" ;;
    *) die "unknown workload '$WORKLOAD' (use: c | mpi | dlio | python-ml)" ;;
esac
cat "$RES/workload.out"
SENDS="$(grep -c 'darshan-mofka\[timing\] send' "$RES/workload.err" || true)"
echo "sends: $SENDS"; [[ "$SENDS" -gt 0 ]] || echo "WARN: 0 sends"

# ---------------------------------------------------------------------------
# 7. flush + export mongo -> JSONL
# ---------------------------------------------------------------------------
say "7. flush + export"
touch "$RUN_DIR/SHUTDOWN"
until grep -q 'Export now' "$RUN_DIR/flowcept.out"; do
    kill -0 "$FC" 2>/dev/null || { tail -40 "$RUN_DIR/flowcept.out"; die "consumer died before export"; }
    sleep 1
done
"$PY" Client/export_jsonl.py 127.0.0.1 "$MONGO_DB" --mongo-port "$MONGO_PORT" \
    > "$EVENTS" 2> "$RES/export.count"
kill "$FC" 2>/dev/null || true; wait "$FC" 2>/dev/null || true
cat "$RES/export.count" || true
echo "exported lines: $(wc -l < "$EVENTS")"
grep -E 'INGEST:|tasks total=' "$RUN_DIR/flowcept.out" | tee -a "$RES/ingest.txt" || true

# ---------------------------------------------------------------------------
# 8. verify event summary
# ---------------------------------------------------------------------------
say "8. verify events"
"$PY" - "$EVENTS" <<'PY' | tee "$RES/summary.txt"
import json, sys
from collections import Counter
mods, ops = Counter(), Counter()
for line in open(sys.argv[1]):
    ev = json.loads(line); mods[ev.get('module')] += 1; ops[ev.get('op')] += 1
print("modules:", dict(mods)); print("ops:", dict(ops))
PY

# ---------------------------------------------------------------------------
# 9. reconstruct + 1:1 compare to native
# ---------------------------------------------------------------------------
say "9. reconstruct + compare to native"
PARTIAL="$RES/partial.darshan"; rm -f "$PARTIAL"
"$B/darshan-mofka-reconstruct" "$EVENTS" "$PARTIAL" || die "reconstruct failed"
NATIVE="$(find "$DARSHAN_LOGPATH" -name "$NATIVE_GLOB" -newermt "-20 min" 2>/dev/null | sort | tail -1)"
echo "native: ${NATIVE:-<none found>}"
"$B/darshan-parser" --show-incomplete "$PARTIAL" | grep -E "^(POSIX|STDIO|MPIIO)" | sort > "$RES/r.txt" || true
if [[ -n "$NATIVE" ]]; then
    cp "$NATIVE" "$RES/native.darshan"
    "$B/darshan-parser" --show-incomplete "$NATIVE" | grep -E "^(POSIX|STDIO|MPIIO)" | sort > "$RES/n.txt" || true
fi
# PASS criterion: reconstructed module set + open/read/write/close counts match native.
"$PY" - "$RES/r.txt" "${RES}/n.txt" "$SENDS" <<'PY' | tee "$RES/compare.txt"
import sys, re, os
from collections import Counter
def counts(path):
    mods=set(); ops=Counter()
    if not os.path.exists(path): return mods, ops
    for ln in open(path):
        f=ln.split()
        if len(f)<4: continue
        mods.add(f[0]); c=f[3]
        for op in ("OPENS","READS","WRITES","OPENS","CLOSES"):
            if c.endswith("_"+op) or c==("%s_%s"%(f[0],op)):
                ops[op]+=1
    return mods, ops
def opcounts(path):
    # count *_OPENS/_READS/_WRITES/_CLOSES counter *values* summed across records
    v=Counter()
    if not os.path.exists(path): return v
    for ln in open(path):
        f=ln.split()
        if len(f)<5: continue
        cn=f[3]
        for op in ("OPENS","READS","WRITES","CLOSES"):
            if cn.endswith("_%s"%op):
                try: v[op]+=int(f[4])
                except ValueError: pass
    return v
r_mods,_=counts(sys.argv[1]); n_mods,_=counts(sys.argv[2])
r_ops=opcounts(sys.argv[1]); n_ops=opcounts(sys.argv[2])
print("reconstructed modules:", sorted(r_mods), " op-totals:", dict(r_ops))
print("native        modules:", sorted(n_mods), " op-totals:", dict(n_ops))
native_present = os.path.exists(sys.argv[2]) and n_mods
if not native_present:
    print("VERDICT: PARTIAL (no native log to compare; reconstruct produced modules %s)" % sorted(r_mods))
    sys.exit(0)
ok = (r_mods==n_mods) and all(r_ops.get(k)==n_ops.get(k) for k in ("OPENS","READS","WRITES","CLOSES"))
print("VERDICT:", "PASS" if ok else "MISMATCH",
      "(known-OK diffs: mount label unknown vs rootfs, timestamps, pid, job/exe meta)")
sys.exit(0 if ok else 3)
PY
CMP_RC=${PIPESTATUS[0]}

# ---------------------------------------------------------------------------
# 10. pydarshan HTML summary (run from results dir so repo darshan/ doesn't shadow)
# ---------------------------------------------------------------------------
say "10. pydarshan HTML summary"
if [[ -f "$RES/native.darshan" ]]; then
    ( cd "$RES" && "$PY" -m darshan summary native.darshan >/dev/null 2>&1 \
        && echo "  HTML: $(ls "$RES"/*.html 2>/dev/null | head -1)" ) \
        || echo "  (pydarshan summary skipped/failed -- non-fatal)"
else
    echo "  (no native.darshan; skipping HTML)"
fi

say "DONE ($WORKLOAD)"
echo "results dir: $RES"
echo "  events.jsonl partial.darshan native.darshan compare.txt summary.txt"
echo "compare verdict rc=$CMP_RC (0=pass/partial, 3=mismatch)"
[[ "$CMP_RC" == 3 ]] && exit 3 || exit 0
