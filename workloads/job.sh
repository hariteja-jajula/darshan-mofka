#!/bin/bash
# workloads/job.sh -- the ONE runner. Reads workloads/workload.config (what + where) and
# server/server.config (how it streams), stands up the broker + FlowCept consumer per the
# topology, runs the workload under the Darshan->Mofka connector, then reconstructs a
# partial .darshan log and compares it 1:1 to the native log. Any topology -- single node,
# broker-per-node, or a server/workload split -- comes from the config, not a per-case script.
#
# Run inside a PBS allocation sized by submit.sh:  PBS_ACCOUNT=<acct> bash submit.sh
# (submit.sh reads topology.nodes/tasks + pbs.* from workloads/workload.config.)
#   SKIP_BUILD=1  reuse an existing darshan/diaspora/util build
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
SKIP_BUILD="${SKIP_BUILD:-0}"
[ -n "${1:-}" ] && export WORKLOAD="$1"      # positional arg overrides workloads/workload.config
say() { printf '\n########## %s ##########\n' "$*"; }
die() { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

# --- 1. environment + resolved run ---
say "1. environment"
export TERM="${TERM:-xterm}"
# shellcheck disable=SC1091
source env/server.sh   || die "could not source env/server.sh"
# shellcheck disable=SC1091
source env/workload.sh || die "could not source env/workload.sh"
module unload darshan 2>/dev/null || true
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
darshan_ensure_logdir >/dev/null
# shellcheck disable=SC1091
source lib/run.sh || die "could not source lib/run.sh"
load_run_config; WORKLOAD="$WL_TYPE"
echo "profile=$ENV_PROFILE  CC=$CC  PY=$PY"
echo "run: workload=$WL_TYPE events=$WL_EVENTS checkpoints=$WL_CHECKPOINTS reps=$WL_REPS"
echo "topology: nodes=$WL_NODES tasks=$WL_TASKS placement=$WL_PLACEMENT brokers=$WL_BROKERS"
echo "stream: topic=$SRV_TOPIC partitions=$SRV_PARTITIONS/$SRV_PART_TYPE protocol=$SRV_PROTOCOL connector.enable=$C_ENABLE mongo=$SRV_MONGO_DB:$SRV_MONGO_PORT"

# --- 2. build (connector + util + workload binary) ---
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
    say "2b. build darshan runtime + util"
    # MPI workloads need the MPI-aware build (install-mpi) so Darshan instruments MPI-IO
    # and finalizes correctly on every rank; non-MPI workloads use the plain build.
    if [[ "$WL_TYPE" == "mpi" ]]; then
        DARSHAN_MPI=1 ./build.sh || die "darshan MPI build failed"
    else
        ./build.sh || die "darshan build failed"
    fi
    [[ -e "$(darshan_lib)" ]] || die "libdarshan.so missing after build"
    ( cd darshan/darshan-util
      if [[ ! -f _build_util/Makefile ]]; then
          ( cd .. && ./prepare.sh ); mkdir -p _build_util
          ( cd _build_util && ../configure --prefix="$PWD/../install" )
      fi
      ( cd _build_util && make -j4 && make install ) ) || die "darshan-util build failed"
fi
B="$ROOT/darshan/darshan-util/install/bin"
[[ -x "$B/darshan-parser" && -x "$B/darshan-mofka-reconstruct" ]] || die "darshan-util tools missing (run without SKIP_BUILD)"

# --- 3. mongod ---
MONGOD="${MONGOD:-$(command -v mongod || true)}"
[[ -x "$MONGOD" ]] || die "mongod not found; run Database/get_mongod.sh or set MONGOD=/path"
export MONGOD

# --- 4. topology: node list + roles ---
# NB: array name must NOT be NODES/EVENTS etc. -- those are config-override var names
# that _cfg_env reads, so a shell var of that name would corrupt the config value.
mapfile -t NODELIST < <(sort -u "${PBS_NODEFILE:-/dev/null}" 2>/dev/null)
[[ ${#NODELIST[@]} -ge 1 ]] || NODELIST=("$(hostname)")
NRANKS_BROKER=$([[ "$WL_BROKERS" == per-node ]] && echo "${#NODELIST[@]}" || echo 1)
SRV_NODE="${NODELIST[0]}"
# workload nodes: separate -> every node except the broker head; colocated -> all nodes.
if [[ "$WL_PLACEMENT" == separate && ${#NODELIST[@]} -ge 2 ]]; then
    WL_NODES_ARR=("${NODELIST[@]:1}")
else
    WL_NODES_ARR=("${NODELIST[@]}")
fi
WL_NNODES=${#WL_NODES_ARR[@]}
WL_TOTAL_RANKS=$(( WL_TASKS * WL_NNODES ))
WL_NODE="${WL_NODES_ARR[0]}"   # kept for messages / single-node paths
# Hostfile of the workload nodes with real slots declared (slots = this node's entry count in
# PBS_NODEFILE, which mpiprocs=ncpus makes = cores). A hostfile both RESTRICTS placement to the
# workload nodes (excludes the broker head) and declares slots reliably, so
# --map-by ppr:WL_TASKS:node puts exactly WL_TASKS ranks/node with NO oversubscription.
WL_SLOTS="$(awk -v n="${WL_NODES_ARR[0]}" '$1==n{c++} END{print c+0}' "${PBS_NODEFILE:-/dev/null}" 2>/dev/null)"
[ "${WL_SLOTS:-0}" -ge 1 ] 2>/dev/null || WL_SLOTS="$(nproc 2>/dev/null || echo 128)"
WL_HOSTFILE="$ROOT/server/_wl_hostfile"
# PALS (polaris) wants a PLAIN hostfile -- it treats "HOST slots=N" as one hostname and
# errors ("Couldn't connect to tcp://HOST slots=N"). It gets per-node density from --ppn +
# the PBS reservation, not the file. OpenMPI (lcrc) needs the "slots=" declaration.
if [[ "$ENV_PROFILE" == polaris ]]; then
    printf '%s\n' "${WL_NODES_ARR[@]}" > "$WL_HOSTFILE"
else
    : > "$WL_HOSTFILE"; for h in "${WL_NODES_ARR[@]}"; do echo "$h slots=$WL_SLOTS" >> "$WL_HOSTFILE"; done
fi
say "topology: ${#NODELIST[@]} node(s) | broker ranks=$NRANKS_BROKER on ${SRV_NODE} | workload ${WL_TASKS} task/node x ${WL_NNODES} node = ${WL_TOTAL_RANKS} rank(s) on: ${WL_NODES_ARR[*]}"

# --- 5. broker (single or one-per-node via tm), created once ---
say "5. broker"
pkill -f 'bedrock ' 2>/dev/null || true; sleep 1
start_broker "$ROOT/server/_broker" "$NRANKS_BROKER" || die "broker failed"
trap 'kill "$BROKER_PID" 2>/dev/null; pkill -f "bedrock " 2>/dev/null || true' EXIT
echo "broker up: $(grep -oE '[a-z0-9+;_]+://[0-9.]+:[0-9]+' "$GROUP" | head -1) | group $GROUP"

# --- 6. compile the workload binary (c/mpi) once ---
case "$WL_TYPE" in
    c)   "$CC" -O2 workloads/c/mofka_forward_smoke.c -o workloads/c/mofka_forward_smoke || die "compile failed" ;;
    mpi) # Ensure the MPI-aware darshan lib exists (needed even under SKIP_BUILD, since the
         # plain build section may have been skipped); build it once if absent.
         [[ -e "$ENV_ROOT/darshan/install-mpi/lib/libdarshan.so" ]] || DARSHAN_MPI=1 ./build.sh >/dev/null 2>&1 || die "darshan MPI build failed"
         MPICC="$(command -v mpicc || echo "$CC")"
         "$MPICC" -O2 workloads/mpi/mofka_forward_mpiio.c -o workloads/mpi/mofka_forward_mpiio || die "compile failed" ;;
esac

# run the workload once into $1 (=RES); places it per WL_PLACEMENT / WL_TASKS
run_workload_once() {
    local RES="$1" scratch="/tmp/dm_${WL_TYPE}_$$_$RANDOM" dlib; dlib="$(darshan_lib)"
    connector_env "$GROUP"; darshan_env; workload_env
    local cmd=()
    case "$WL_TYPE" in
        c)         cmd=(./workloads/c/mofka_forward_smoke "$scratch") ;;
        python-ml) cmd=("$PY" workloads/python-ml/train.py "$scratch") ;;
        mpi)       cmd=(./workloads/mpi/mofka_forward_mpiio "$scratch") ;;
        dlio)      # DLIO benchmark from its own isolated venv (install/_dlio_venv); tensorflow
                   # data loader avoids the torch/DALI(GPU) deps. generate_data only: distributed
                   # dataset writes = real POSIX I/O captured by the LD_PRELOAD connector, fast, and
                   # no slow CPU TF train loop (train=True dominates wall time and floods finalize).
                   # num_files scales with WL_EVENTS. See workloads/dlio/README.md.
                   cmd=("$ROOT/install/_dlio_venv/bin/dlio_benchmark"
                        "++workload.workflow.generate_data=True" "++workload.workflow.train=False"
                        "++workload.framework=tensorflow" "++workload.reader.data_loader=tensorflow"
                        "++workload.dataset.format=npz" "++workload.dataset.data_folder=$scratch"
                        "++workload.dataset.num_files_train=${WL_EVENTS}"
                        "++workload.dataset.num_samples_per_file=4"
                        "++workload.dataset.record_length=4096"
                        "++hydra.run.dir=$scratch/hydra" "++hydra.output_subdir=null") ;;
        *)         die "unknown workload '$WL_TYPE'" ;;
    esac
    local base=(DARSHAN_LOGPATH="$RES" LD_PRELOAD="$dlib" "${CONNECTOR_ENV[@]}" "${DARSHAN_ENV[@]}" "${WORKLOAD_ENV[@]}")
    # Fast path: a single local rank on the head node needs no launcher. Otherwise place
    # WL_TASKS ranks per workload node (multi-proc and/or multi-node) with ppr mapping --
    # NO oversubscription (WL_TASKS must be <= ncpus/node or PRRTE errors, which is correct).
    if [[ "$WL_TOTAL_RANKS" -le 1 && "$WL_NNODES" -le 1 && "$WL_NODE" == "$SRV_NODE" && "$WL_TYPE" != mpi && "$WL_TYPE" != dlio ]]; then
        env "${base[@]}" "${cmd[@]}" > "$RES/workload.out" 2> "$RES/workload.err"
    else
        local estr="${CONNECTOR_ENV[*]} ${DARSHAN_ENV[*]} ${WORKLOAD_ENV[*]}"
        mpi_launch "$WL_TOTAL_RANKS" "$WL_TASKS" "$WL_HOSTFILE"
        "${MPI_LAUNCH[@]}" bash -lc \
          "cd '$ROOT' && source env/workload.sh >/dev/null 2>&1 && env $estr DARSHAN_LOGPATH='$RES' LD_PRELOAD='$dlib' ${cmd[*]}" \
          > "$RES/workload.out" 2> "$RES/workload.err"
    fi
}

# --- 7. reps: run + drain + reconstruct + compare, into descriptive RUN<n> dirs ---
RESBASE="$ROOT/results/$(results_dir_name)"
FINAL_RC=0
for rep in $(seq 1 "$WL_REPS"); do
    RES="$(next_run_dir "$RESBASE")"; mkdir -p "$RES"
    say "run $rep/$WL_REPS -> $RES"
    RUN_DIR="$ROOT/server/_flowcept_run"; rm -rf "$RUN_DIR"
    start_consumer "$RUN_DIR" "$GROUP" || die "consumer failed"
    run_workload_once "$RES"; cat "$RES/workload.out"
    SENDS="$(grep -c 'darshan-mofka\[timing\] send' "$RES/workload.err" 2>/dev/null || true)"; SENDS=${SENDS:-0}
    echo "sends: $SENDS"
    EVJSONL="$RES/events.jsonl"
    stop_consumer_verdict "$RUN_DIR" "$RES/ingest.txt" "$EVJSONL"   # exports before killing mongod
    echo "exported lines: $(wc -l < "$EVJSONL")"
    # Reconstruct ONE .darshan per process (pid) into streamed/ -- mirroring native's
    # per-process output. Then collect the native per-process logs into native/ so the
    # two directories hold the SAME set of files (one per process) for a 1:1 comparison.
    STREAMED_DIR="$RES/streamed"; NATIVE_DIR="$RES/native"
    rm -rf "$STREAMED_DIR" "$NATIVE_DIR"; mkdir -p "$STREAMED_DIR" "$NATIVE_DIR"
    "$B/darshan-mofka-reconstruct" "$EVJSONL" "$STREAMED_DIR" || die "reconstruct failed"
    # Native per-process logs from this run (each process writes its own nprocs=1 log).
    # EXCLUDE the reconstructed logs we just wrote under $RES/streamed (and anything already
    # copied into $RES/native): find scans $RES recursively and would otherwise sweep the
    # reconstructed .darshan back in as if it were native -> duplicate-pid ERROR in
    # strict_compare (VERDICT: ERROR rc=2). Mirrors overhead_study.sh's ! -path guard. (BX 2026-07-27)
    mapfile -t NATIVE_LOGS < <(find "$RES" "$DARSHAN_LOGPATH" -name '*.darshan' \
        ! -path "$STREAMED_DIR/*" ! -path "$NATIVE_DIR/*" -newermt '-20 min' 2>/dev/null | sort)
    for nl in "${NATIVE_LOGS[@]}"; do cp "$nl" "$NATIVE_DIR/"; done
    # STRICT compare: reconstructed vs native, EXACT integer counters per record.
    # (Replaces the old summed-4-op-total rubber stamp -- that hid real capture gaps.)
    # Mode by workload class: non-MPI workloads (c/python-ml/dlio) write one log per
    # process -> per-process/per-record/per-counter exact compare. MPI writes ONE shared
    # log reduced to rank=-1 -> aggregate the N reconstructed per-rank logs the way
    # Darshan's reduction does, then compare. See workloads/strict_compare.py.
    # Run from $RES so the repo's darshan/ source tree doesn't shadow the pydarshan pkg.
    cmp_mode="perproc"; [[ "$WL_TYPE" == "mpi" ]] && cmp_mode="mpi"   # NOT `local`: this block runs in the main-body for-loop, not a function
    ( cd "$RES" && "$PY" "$ROOT/workloads/strict_compare.py" streamed native "$cmp_mode" ) \
        | tee "$RES/compare.txt"
    # exit 3 = MISMATCH (real capture bug), 2 = ERROR (harness/config failure, e.g. no
    # native logs). BOTH must fail the run -- a config failure must not score as a pass.
    CMP_RC="${PIPESTATUS[0]}"; [[ "$CMP_RC" == 3 || "$CMP_RC" == 2 ]] && FINAL_RC="$CMP_RC"
    # pydarshan HTML for ONE example process, native AND reconstructed, for a side-by-side
    # visual. pydarshan renders a single per-process log (a merged multi-process log has mixed
    # heatmap nbins and pydarshan rejects it -- native has the same limit, so we stay per-file).
    # Run from the results dir so the repo's darshan/ source tree doesn't shadow the package.
    ( cd "$RES"
      ONE_NAT="$(ls native/*.darshan 2>/dev/null | head -1)"
      ONE_REC="$(ls streamed/*.darshan 2>/dev/null | head -1)"
      [[ -n "$ONE_NAT" ]] && cp "$ONE_NAT" example_native.darshan  && "$PY" -m darshan summary example_native.darshan  >/dev/null 2>&1 || true
      [[ -n "$ONE_REC" ]] && cp "$ONE_REC" example_streamed.darshan && "$PY" -m darshan summary example_streamed.darshan >/dev/null 2>&1 || true
      echo "  example HTML: $(ls example_native_report.html example_streamed_report.html 2>/dev/null | tr '\n' ' ')" ) || true
done

say "DONE ($WL_TYPE, $WL_REPS rep(s))"
echo "results: $RESBASE/RUN*"
exit "$FINAL_RC"
