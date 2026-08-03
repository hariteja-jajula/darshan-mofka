#!/bin/bash
# probe_tcp_ab.sh -- prove (on verbs/TCP) whether the yielding progress-thread config
# makes the Mofka client progress thread SLEEP instead of busy-polling a core.
#
# Runs inside ONE PBS allocation (same node -> arms directly comparable). Forces
# MOFKA_PROTOCOL=ofi+tcp, stands up a broker + topic once, then runs the SAME workload
# three ways under run_artifacts/cpu_probe.sh:
#
#   1. baseline   -- DARSHAN_MOFKA_ENABLE=0 (Darshan on, no streaming)  -> expect cpu_self==cpu_thread
#   2. spinning   -- streaming, default engine (use_progress_thread:true, basic sched) -> reproduce peg
#   3. yielding   -- streaming, margo config = fifo_wait pool + basic_wait xstream + rpc_thread_count:0
#                    (the declarative equivalent of Mofka's start_progress_thread() in work.py)
#
# Read the result:  cpu_self ~= 2*cpu_thread  => still spinning (peg).
#                   cpu_self ~= cpu_thread     => thread sleeps, core reclaimed (FIX WORKS on TCP).
#
# Submit (does NOT run on login node):
#   PBS_ACCOUNT=radix-io QUEUE=debug NODES=1 WALLTIME=00:40:00 qsub \
#       -A radix-io -q debug -l select=1:ncpus=32:mpiprocs=32 -l walltime=00:40:00 \
#       -N dm_probe -j oe -o run_artifacts/../results/ \
#       -- run_artifacts/probe_tcp_ab.sh
# or add a small wrapper mirroring submit_small.sh. This script only RUNS inside the alloc.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
say() { printf '\n########## %s ##########\n' "$*"; }
die() { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

# --- fabric: default TCP; set MOFKA_PROTOCOL=verbs (or ofi+verbs) to run the verbs arm set.
# Both TCP and verbs CAN block-wait, so the yielding fix is expected to work on both. ---
export MOFKA_PROTOCOL="${MOFKA_PROTOCOL:-ofi+tcp}"
export WORKLOAD="${WORKLOAD:-io_bench_py}"     # bandwidth-sensitive python == the worst case (+43%)
export EVENTS="${EVENTS:-8}"
export REPS=1
export NODES=1 TASKS=1
# Give the work window enough duration for a stable CPU ratio: ~40 iters, matmul compute so
# the app thread does real bandwidth-touching work (that's what the pegged core steals from).
# Work region must outlast warmup+window (~30s). Pure-python matmul is very slow, so keep
# COMPUTE modest and lean on iters+sleep to span the window while the app thread stays busy
# with bandwidth-touching work (what the pegged progress core steals from).
export IO_ITERS="${IO_ITERS:-60}"
export IO_SLEEP_MS="${IO_SLEEP_MS:-0}"
export COMPUTE="${COMPUTE:-1}"
export MATRIX_SIZE="${MATRIX_SIZE:-200}"

# --- environment + config (same as workloads/job.sh) ---
say "env"
export TERM="${TERM:-xterm}"
source env/server.sh   || die "env/server.sh"
source env/workload.sh || die "env/workload.sh"
module unload darshan 2>/dev/null || true
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
darshan_ensure_logdir >/dev/null
source lib/run.sh || die "lib/run.sh"
load_run_config
echo "protocol=$SRV_PROTOCOL workload=$WL_TYPE events=$WL_EVENTS iters=$IO_ITERS compute=$COMPUTE"

# --- build once (reuse if present) ---
if [[ "${SKIP_BUILD:-0}" = "1" && -e "$(darshan_lib 2>/dev/null)" ]]; then
    say "build (SKIP_BUILD=1, using $(darshan_lib))"
else
    # Always (re)build diaspora-stream-api: the shim gained diaspora_producer_create_ex,
    # so a header-existence guard would skip the needed rebuild. cmake is incremental.
    say "build diaspora-stream-api (incremental)"
    ( cd diaspora-stream-api \
      && cmake -S . -B _build -DENABLE_C_API=ON -DENABLE_PYTHON=ON \
            -DCMAKE_PREFIX_PATH="$MOFKA_SPACK_VIEW" -DCMAKE_INSTALL_PREFIX="$PWD/install" \
      && cmake --build _build -j4 && cmake --install _build ) || die "diaspora build failed"
    say "build darshan runtime"
    ./build.sh || die "darshan build failed"
    [[ -e "$(darshan_lib)" ]] || die "libdarshan.so missing after build"
fi
DLIB="$(darshan_lib)"; export DARSHAN_LIB_SO="$DLIB"
echo "libdarshan.so = $DLIB"

# --- results dir ---
RES="$ROOT/results/PROBE_TCP_$(date +%Y%m%d_%H%M%S)"; mkdir -p "$RES"
LOG="$RES/probe.log"; echo "results -> $RES" | tee "$LOG"

# --- stand up the broker + topic ONCE (shared by all streaming arms) ---
say "broker (TCP)" | tee -a "$LOG"
start_broker "$RES/server" 1 || die "broker failed to start"
[ -n "${GROUP:-}" ] || GROUP="$RES/server/mofka.json"
broker_topic_partitions "$GROUP" 1 || die "topic/partitions failed"
echo "GROUP=$GROUP" | tee -a "$LOG"

# --- the yielding config: declarative equivalent of work.py start_progress_thread() ---
# fifo_wait pool + basic_wait scheduler => the ES sleeps when its pool is empty.
# rpc_thread_count:0 => pure producer, no RPC-servicing threads to spin either.
YIELD_JSON='{"use_progress_thread":true,"rpc_thread_count":0,"argobots":{"pools":[{"name":"__progress__","kind":"fifo_wait","access":"mpmc"}],"xstreams":[{"name":"__progress__","scheduler":{"type":"basic_wait","pools":["__progress__"]}}]}}'

# --- resolve the workload command + a scratch dir ---
scratch="$RES/scratch"; mkdir -p "$scratch"
case "$WL_TYPE" in
    io_bench_py) CMD=("$PY" workloads/python-ml/io_bench.py "$scratch") ;;
    io_bench)    CMD=(./workloads/c/io_bench "$scratch") ;;
    python-ml)   CMD=("$PY" workloads/python-ml/train.py "$scratch") ;;
    *) die "probe supports io_bench_py|io_bench|python-ml; got $WL_TYPE" ;;
esac
workload_env; darshan_env

# --- run one arm: <tag> <enable> <producer_threads> [margo_json] ---
# producer_threads=0 -> sender ULT shares the margo progress pool (the BUG: wedge/overhead).
# producer_threads=1 -> dedicated Argobots ES for the sender (the FIX).
# cpu_probe samples a fixed warmup+window then kills the pid (teardown may hang).
run_arm() {
    local tag="$1" enable="$2" pthreads="$3" margo="${4:-}"
    say "ARM: $tag (enable=$enable producer_threads=$pthreads margo=${margo:+set})" | tee -a "$LOG"
    connector_env "$GROUP"
    local envv=( "${CONNECTOR_ENV[@]}" "${DARSHAN_ENV[@]}" "${WORKLOAD_ENV[@]}" )
    envv+=( DARSHAN_MOFKA_ENABLE="$enable" DARSHAN_MOFKA_VERBOSE=1 PYTHONUNBUFFERED=1
            DARSHAN_MOFKA_JOIN_MS="${JOIN_MS:-3000}" DARSHAN_MOFKA_FLUSH_MS="${FLUSH_MS:-3000}"
            DARSHAN_MOFKA_FAST_EXIT="${FAST_EXIT:-1}"
            DARSHAN_MOFKA_PRODUCER_THREADS="$pthreads" )
    [ -n "$margo" ] && envv+=( DARSHAN_MOFKA_MARGO_JSON="$margo" )
    local out="$RES/workload.$tag.out" err="$RES/workload.$tag.err"
    env "${envv[@]}" DARSHAN_LOGPATH="$RES/darshan.$tag" LD_PRELOAD="$DLIB" \
        bash run_artifacts/cpu_probe.sh "$tag" "${WARMUP_S:-8}" "${WINDOW_S:-20}" -- "${CMD[@]}" \
        > "$out" 2> "$err"
    grep -h "^CPU_PROBE" "$out" "$err" 2>/dev/null | tee -a "$LOG"
    grep -h "producer connected\|drain join timed out\|fast-exit" "$err" 2>/dev/null | head -3 | tee -a "$LOG"
}

say "ARMS" | tee -a "$LOG"
run_arm baseline 0 0 ""          # no streaming (control)
run_arm poolbug  1 0 ""          # streaming, sender on progress pool (reproduces wedge)
run_arm poolfix  1 1 ""          # streaming, dedicated producer ES (the fix)

# --- teardown ---
say "teardown" | tee -a "$LOG"
[ -n "${BROKER_PID:-}" ] && kill "$BROKER_PID" 2>/dev/null || true

say "SUMMARY (protocol=$SRV_PROTOCOL)" | tee -a "$LOG"
echo "Interpretation:" | tee -a "$LOG"
echo "  baseline: control (no streaming)"                                          | tee -a "$LOG"
echo "  poolbug : sender on progress pool -> expect wedge / drain-join-timeout"    | tee -a "$LOG"
echo "  poolfix : dedicated producer ES -> expect clean run, no wedge, good wall"  | tee -a "$LOG"
echo "  KEY: does poolfix complete cleanly (no 'drain join timed out') and match"  | tee -a "$LOG"
echo "       baseline wall, where poolbug wedges? That validates the ThreadPool fix." | tee -a "$LOG"
grep "^CPU_PROBE" "$LOG" | tee -a "$LOG"
echo "done: $RES"
