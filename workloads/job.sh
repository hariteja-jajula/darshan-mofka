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
source env/server.sh   || die "could not source env/server.sh"
source env/workload.sh || die "could not source env/workload.sh"
module unload darshan 2>/dev/null || true
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
darshan_ensure_logdir >/dev/null
source lib/run.sh || die "could not source lib/run.sh"
load_run_config; WORKLOAD="$WL_TYPE"
# RUN_MODE: mpmd = single-MPMD ofi+cxi path (broker+consumer+workload in ONE launch, shared
# job VNI); legacy = old 3-launch TCP baseline (still selectable). cxi -> mpmd.
RUN_MODE="${RUN_MODE:-$([[ "$SRV_PROTOCOL" == *cxi* ]] && echo mpmd || echo legacy)}"
# Gate-0: MPI_Init hangs beside a stripped MPMD section -> MPI-IO can't stream over cxi/mpmd.
# It stays on the legacy/TCP baseline. (run_artifacts/DECISION.md, fork resolved non-MPI only.)
[[ "$RUN_MODE" == mpmd && "$WL_TYPE" == mpi ]] && die "WL_TYPE=mpi unsupported in mpmd/cxi mode (Gate-0); use RUN_MODE=legacy for the MPI baseline"
# Gate-1: over cxi/mpmd the supported non-MPI shape is 1 rank PER NODE. Multi-rank/node C/io_bench/
# python-ml floods the single broker -> proven ~85% event loss (C N2T4 500K MISMATCH) or ceiling
# timeout / PALS node drop at scale (C N5T4 16-rank). For multi-rank runs use the TCP/legacy path
# (MOFKA_PROTOCOL=ofi+tcp), which is also how MPI/dlio run. (Overnight 2026-07-31 evidence.)
[[ "$RUN_MODE" == mpmd && "${WL_TASKS:-1}" -gt 1 ]] && die "WL_TASKS=$WL_TASKS (>1 rank/node) unsupported in mpmd/cxi mode (Gate-1): cxi streaming is 1-rank/node only. For multi-rank use MOFKA_PROTOCOL=ofi+tcp (legacy path, same as MPI/dlio)."
echo "profile=$ENV_PROFILE  CC=$CC  PY=$PY  run_mode=$RUN_MODE"
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
# Resolve libdarshan.so ONCE here (post-build, so the mpi/dlio install-mpi path is correct);
# run_mpmd_rep reuses this instead of re-running darshan_lib every rep.
DARSHAN_LIB_SO="$(darshan_lib)"; export DARSHAN_LIB_SO

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
# Broker hostfile: pins the single ofi+cxi broker to node 0 (start_broker launches it under
# mpiexec so it inherits the job VNI). Plain hostname (PALS) / slots= (OpenMPI), same as above.
BROKER_HOSTFILE="$ROOT/server/_broker_hostfile"
if [[ "$ENV_PROFILE" == polaris ]]; then
    printf '%s\n' "$SRV_NODE" > "$BROKER_HOSTFILE"
else
    echo "$SRV_NODE slots=$WL_SLOTS" > "$BROKER_HOSTFILE"
fi
say "topology: ${#NODELIST[@]} node(s) | broker ranks=$NRANKS_BROKER on ${SRV_NODE} | workload ${WL_TASKS} task/node x ${WL_NNODES} node = ${WL_TOTAL_RANKS} rank(s) on: ${WL_NODES_ARR[*]}"

# --- 5. broker: legacy only. mpmd launches broker per-rep inside run_mpmd_rep (one VNI). ---
if [[ "$RUN_MODE" == legacy ]]; then
    say "5. broker (legacy)"
    pkill -f 'bedrock ' 2>/dev/null || true; sleep 1
    start_broker "$ROOT/server/_broker" "$NRANKS_BROKER" "$BROKER_HOSTFILE" || die "broker failed"
    trap 'kill "$BROKER_PID" 2>/dev/null; pkill -f "bedrock " 2>/dev/null || true' EXIT
    echo "broker up: $(grep -oE '[a-z0-9+;_]+://[0-9.]+:[0-9]+' "$GROUP" | head -1) | group $GROUP"
else
    say "5. broker (mpmd: launched per-rep in one MPMD mpiexec)"
    trap 'pkill -f "bedrock " 2>/dev/null || true' EXIT
fi

# --- 6. compile the workload binary (c/mpi) once ---
case "$WL_TYPE" in
    c)        "$CC" -O2 workloads/c/mofka_forward_smoke.c -o workloads/c/mofka_forward_smoke || die "compile failed" ;;
    io_bench) "$CC" -O2 workloads/c/io_bench.c -o workloads/c/io_bench || die "compile failed" ;;  # moderate-I/O, non-MPI
    io_bench_py) : ;;  # Python twin of io_bench -- no compile step
    mpi) # Ensure the MPI-aware darshan lib exists (needed even under SKIP_BUILD, since the
         # plain build section may have been skipped); build it once if absent.
         [[ -e "$ENV_ROOT/darshan/install-mpi/lib/libdarshan.so" ]] || DARSHAN_MPI=1 ./build.sh >/dev/null 2>&1 || die "darshan MPI build failed"
         # Build the MPI workload with the SAME MPI toolchain as the MPI-aware libdarshan
         # (build.sh forces craype `cc` on polaris -> cray-mpich 9.0.1). Using the craype
         # `cc` wrapper here too keeps the app and the LD_PRELOAD'd libdarshan on one
         # cray-mpich version; a bare `mpicc` is a GNU cray-mpich 8.1.28 wrapper -- it only
         # works by soname luck (both need libmpi_gnu_123.so.12). On LCRC, mpicc (openmpi).
         if [[ "$ENV_PROFILE" == polaris ]]; then
             MPICC="${MPI_WL_CC:-cc}"
         else
             MPICC="${MPI_WL_CC:-$(command -v mpicc || echo "$CC")}"
         fi
         "$MPICC" -O2 workloads/mpi/mofka_forward_mpiio.c -o workloads/mpi/mofka_forward_mpiio || die "compile failed" ;;
esac

# run the workload once into $1 (=RES); places it per WL_PLACEMENT / WL_TASKS
run_workload_once() {
    local RES="$1" scratch="/tmp/dm_${WL_TYPE}_$$_$RANDOM" dlib; dlib="$(darshan_lib)"
    connector_env "$GROUP"; darshan_env; workload_env
    local cmd=()
    case "$WL_TYPE" in
        c)         cmd=(./workloads/c/mofka_forward_smoke "$scratch") ;;
        io_bench)  cmd=(./workloads/c/io_bench "$scratch") ;;
        io_bench_py) cmd=("$PY" workloads/python-ml/io_bench.py "$scratch") ;;
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
    # Shell-level WORK window = true workload-process wall (launch->exit), EXCLUDING broker/
    # consumer setup + drain. This is the valid workload wall for workloads that do not self-time
    # (mpi, dlio). Written into workload.out so extract.sh can read WORK_SH_START/END_NS.
    echo "WORK_SH_START_NS $(date +%s%N)" > "$RES/workload.out"
    if [[ "$WL_TOTAL_RANKS" -le 1 && "$WL_NNODES" -le 1 && "$WL_NODE" == "$SRV_NODE" && "$WL_TYPE" != mpi && "$WL_TYPE" != dlio ]]; then
        env "${base[@]}" "${cmd[@]}" >> "$RES/workload.out" 2> "$RES/workload.err"
    else
        # Shell-quote every env assignment with %q so values containing shell metacharacters
        # (e.g. DARSHAN_MOFKA_MARGO_JSON's {}[]":, argobots JSON) survive the double-quoted
        # `bash -lc "... env $estr ..."` re-parse. A plain "${CONNECTOR_ENV[*]}" space-join lets
        # the JSON's embedded quotes terminate the shell string and shred the value.
        local estr=""; local _kv
        for _kv in "${CONNECTOR_ENV[@]}" "${DARSHAN_ENV[@]}" "${WORKLOAD_ENV[@]}"; do
            estr+=" $(printf '%q' "$_kv")"
        done
        # ofi+cxi producer must collapse to the same single VNI the broker used, else it can't
        # attach across nodes over the shared job VNI. cxi_pfx runs inside the launched shell.
        local cxi_pfx=""; [[ "$SRV_PROTOCOL" == *cxi* ]] && cxi_pfx="$(cxi_collapse) "
        mpi_launch "$WL_TOTAL_RANKS" "$WL_TASKS" "$WL_HOSTFILE"
        "${MPI_LAUNCH[@]}" bash -lc \
          "cd '$ROOT' && source env/workload.sh >/dev/null 2>&1 && ${cxi_pfx}env $estr DARSHAN_LOGPATH='$RES' LD_PRELOAD='$dlib' ${cmd[*]}" \
          >> "$RES/workload.out" 2> "$RES/workload.err"
    fi
    echo "WORK_SH_END_NS $(date +%s%N)" >> "$RES/workload.out"
}

# --- 7. reps: run + drain + reconstruct + compare, into descriptive RUN<n> dirs ---
# RESULTS_TAG (optional): override the results subdir name so a study driver can route
# each arm/config into its own labeled dir (e.g. overhead_study.sh). Default = topology name.
RESBASE="$ROOT/results/${RESULTS_TAG:-$(results_dir_name)}"
FINAL_RC=0
for rep in $(seq 1 "$WL_REPS"); do
    RES="$(next_run_dir "$RESBASE")"; mkdir -p "$RES"
    say "run $rep/$WL_REPS -> $RES"
    EVJSONL="$RES/events.jsonl"
    if [[ "$RUN_MODE" == mpmd ]]; then
        # broker + consumer + workload in ONE MPMD mpiexec (shared job VNI); leaves events.jsonl.
        run_mpmd_rep "$RES" || { echo "rep $rep: run_mpmd_rep FAILED"; FINAL_RC=1; }
        [ -f "$RES/workload.out" ] && cat "$RES/workload.out"
    else
        RUN_DIR="$ROOT/server/_flowcept_run"; rm -rf "$RUN_DIR"
        start_consumer "$RUN_DIR" "$GROUP" || die "consumer failed"
        run_workload_once "$RES"; cat "$RES/workload.out"
        SENDS="$(grep -c 'darshan-mofka\[timing\] send' "$RES/workload.err" 2>/dev/null || true)"; SENDS=${SENDS:-0}
        echo "sends: $SENDS"
        stop_consumer_verdict "$RUN_DIR" "$RES/ingest.txt" "$EVJSONL"   # exports before killing mongod
    fi
    echo "exported lines: $(wc -l < "$EVJSONL" 2>/dev/null || echo 0)"
    # Baseline arm (NO_DARSHAN=1): the workload ran without libdarshan, so there are no
    # native logs and nothing was streamed. Skip reconstruct/compare -- the value of this
    # arm is the raw workload wall time (in workload.*.out), not a log comparison.
    if [ "${NO_DARSHAN:-0}" = 1 ]; then
        echo "VERDICT: BASELINE (no-Darshan arm: reconstruct/compare skipped)" | tee "$RES/compare.txt"
        continue
    fi
    # Runtime-only arm (DARSHAN_MOFKA_ENABLE=0): libdarshan ran and wrote a native
    # log, but streamed 0 events -> events.jsonl is empty, so reconstruct/compare
    # has nothing to do. Skip it; this arm's value is the workload wall time (the
    # instrumented-but-not-streaming cost), captured in workload.*.out.
    if [ "${DARSHAN_MOFKA_ENABLE:-1}" = 0 ]; then
        echo "VERDICT: RUNTIMEONLY (no-stream arm: reconstruct/compare skipped)" | tee "$RES/compare.txt"
        continue
    fi
    # Reconstruct ONE .darshan per process (pid) into streamed/ -- mirroring native's
    # per-process output. Then collect the native per-process logs into native/ so the
    # two directories hold the SAME set of files (one per process) for a 1:1 comparison.
    STREAMED_DIR="$RES/streamed"; NATIVE_DIR="$RES/native"
    rm -rf "$STREAMED_DIR" "$NATIVE_DIR"; mkdir -p "$STREAMED_DIR" "$NATIVE_DIR"
    # Time the reconstruct step (meeting ask: how long does reconstruct take?).
    _rc_t0=$(date +%s.%N)
    "$B/darshan-mofka-reconstruct" "$EVJSONL" "$STREAMED_DIR" || die "reconstruct failed"
    _rc_t1=$(date +%s.%N)
    awk -v a="$_rc_t0" -v b="$_rc_t1" 'BEGIN{printf "reconstruct_seconds=%.3f\n", b-a}' | tee "$RES/reconstruct_time.txt"
    # Native per-process logs from this run (each process writes its own nprocs=1 log).
    # EXCLUDE the reconstructed logs we just wrote under $RES/streamed (and anything already
    # copied into $RES/native): find scans $RES recursively and would otherwise sweep the
    # reconstructed .darshan back in as if it were native -> duplicate-pid ERROR in
    # strict_compare (VERDICT: ERROR rc=2). Mirrors overhead_study.sh's ! -path guard.
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
    cmp_mode="perproc"; [[ "$WL_TYPE" == "mpi" || "$WL_TYPE" == "dlio" ]] && cmp_mode="mpi"   # dlio = MPI mode. NOT `local`: this block runs in the main-body for-loop, not a function
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
