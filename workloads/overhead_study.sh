#!/bin/bash
# workloads/overhead_study.sh -- connector overhead study, run inside ONE PBS
# allocation so every arm shares the same nodes (apples-to-apples).
#
# Three arms per workload (equal work each):
#   Baseline_nodarshan_nomofka   - workload with NO LD_PRELOAD (no Darshan, no Mofka)
#   Enable_darshan_runtimeonly   - Darshan LD_PRELOAD, DARSHAN_MOFKA_ENABLE=0 (records, no stream)
#   Streaming_<params>           - Darshan LD_PRELOAD, ENABLE=1, full pipeline (consumer drains)
#
# Per arm/rep it records: wall time, connector initialize cost, finalize cost,
# number of pushes, number of events, per-push mean/median latency. The first
# streaming rep is also reconstructed + compared 1:1 to native (fidelity VERDICT).
# Broker params (partitions, partition type, rpc threads, progress thread) are
# reported once as study parameters. The report is a per-arm table plus the
# derived overhead (Darshan cost, streaming cost) vs the no-Darshan baseline.
#
# Submit:
#   RUN_SCRIPT=workloads/overhead_study.sh STUDY_WORKLOADS="c" STUDY_EVENTS=5000 \
#     STUDY_REPS=3 PBS_ACCOUNT=<acct> bash submit.sh
#   STUDY_WORKLOADS="c python-ml mpi"   # run all variations (space separated)
# Topology (nodes/tasks/placement/brokers) comes from workloads/workload.config.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
SKIP_BUILD="${SKIP_BUILD:-0}"
say()  { printf '\n########## %s ##########\n' "$*"; }
die()  { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }
now()  { date +%s.%N; }

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
load_run_config

STUDY_EVENTS="${STUDY_EVENTS:-$WL_EVENTS}"
STUDY_REPS="${STUDY_REPS:-${WL_REPS:-3}}"
STUDY_WORKLOADS="${STUDY_WORKLOADS:-$WL_TYPE}"   # space-separated: c python-ml mpi
export EVENTS="$STUDY_EVENTS"          # _cfg_env override so the workload scales
export DARSHAN_MOFKA_TIMING=1          # connector init/send/finalize timing -> workload.err
echo "study: workloads=[$STUDY_WORKLOADS] events=$STUDY_EVENTS reps=$STUDY_REPS"
echo "topology: nodes=$WL_NODES tasks=$WL_TASKS placement=$WL_PLACEMENT brokers=$WL_BROKERS"
echo "broker: partitions=$SRV_PARTITIONS type=$SRV_PART_TYPE rpc_threads=$BRK_RPC_THREADS progress_thread=$BRK_PROGRESS"

# --- 2. build ---
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
    ./build.sh || die "darshan build failed"
    [[ -e "$(darshan_lib)" ]] || die "libdarshan.so missing after build"
    ( cd darshan/darshan-util
      if [[ ! -f _build_util/Makefile ]]; then
          ( cd .. && ./prepare.sh ); mkdir -p _build_util
          ( cd _build_util && ../configure --prefix="$PWD/../install" )
      fi
      ( cd _build_util && make -j4 && make install ) ) || die "darshan-util build failed"
fi
B="$ROOT/darshan/darshan-util/install/bin"
[[ -x "$B/darshan-parser" && -x "$B/darshan-mofka-reconstruct" ]] || die "darshan-util tools missing"

# --- 3. mongod ---
MONGOD="${MONGOD:-$(command -v mongod || true)}"
[[ -x "$MONGOD" ]] || die "mongod not found; run Database/get_mongod.sh or set MONGOD=/path"
export MONGOD

# --- 4. topology ---
mapfile -t NODELIST < <(sort -u "${PBS_NODEFILE:-/dev/null}" 2>/dev/null)
[[ ${#NODELIST[@]} -ge 1 ]] || NODELIST=("$(hostname)")
NRANKS_BROKER=$([[ "$WL_BROKERS" == per-node ]] && echo "${#NODELIST[@]}" || echo 1)
SRV_NODE="${NODELIST[0]}"; WL_NODE="$SRV_NODE"
[[ "$WL_PLACEMENT" == separate ]] && WL_NODE="${NODELIST[1]:-${NODELIST[0]}}"
say "topology: ${#NODELIST[@]} node(s) | broker on ${SRV_NODE} | workload on ${WL_NODE}"

# Workload hostfile restricting placement to WL_NODE (mirrors job.sh:88-100). PALS
# (polaris) wants a PLAIN hostfile -- it parses "HOST slots=N" as one hostname -- so
# under polaris write bare hostnames; OpenMPI (lcrc) keeps the "HOST slots=N" form.
# The launcher itself is chosen by mpi_launch() (env/common.sh), never hardcoded here.
WL_SLOTS="$(awk -v n="$WL_NODE" '$1==n{c++} END{print c+0}' "${PBS_NODEFILE:-/dev/null}" 2>/dev/null)"
[[ "$WL_SLOTS" -ge 1 ]] 2>/dev/null || WL_SLOTS="$WL_TASKS"
WL_HOSTFILE="$ROOT/server/_study_wl_hostfile"
if [[ "$ENV_PROFILE" == polaris ]]; then
    printf '%s\n' "$WL_NODE" > "$WL_HOSTFILE"
else
    printf '%s slots=%s\n' "$WL_NODE" "$WL_SLOTS" > "$WL_HOSTFILE"
fi

# --- 5. broker (once) ---
say "5. broker"
pkill -f 'bedrock ' 2>/dev/null || true; sleep 1
start_broker "$ROOT/server/_broker" "$NRANKS_BROKER" || die "broker failed"
trap 'kill "${BROKER_PID:-}" 2>/dev/null; for _cp in "${CONSUMER_PIDS[@]:-}"; do kill "$_cp" 2>/dev/null; done; pkill -f "bedrock " 2>/dev/null || true' EXIT
echo "broker up | group $GROUP"

compile_workload() {  # $1 = workload type
    case "$1" in
        c)   "$CC" -O2 workloads/c/mofka_forward_smoke.c -o workloads/c/mofka_forward_smoke || die "compile c failed" ;;
        mpi) DARSHAN_MPI=1 ./build.sh >/dev/null 2>&1 || true
             # On Polaris the MPI+GCC compiler is the craype `cc` wrapper (links cray-mpich);
             # bare `mpicc` is the PrgEnv-nvidia wrapper (wrong). Mirror workloads/job.sh:122-125.
             local MPICC
             if [[ "${ENV_PROFILE:-}" == polaris ]]; then
                 MPICC="${MPI_WL_CC:-cc}"
             else
                 MPICC="${MPI_WL_CC:-$(command -v mpicc || echo "$CC")}"
             fi
             "$MPICC" -O2 workloads/mpi/mofka_forward_mpiio.c -o workloads/mpi/mofka_forward_mpiio || die "compile mpi failed" ;;
        python-ml) : ;;  # no compile step
        dlio) : ;;       # no compile step; runs from install/_dlio_venv (see run_workload_once dlio case)
        *) die "unknown workload '$1'" ;;
    esac
}

# run one workload rep into $1 (=RES). ARM_MODE (none|runtime|stream) selects whether
# Darshan is preloaded; DARSHAN_MOFKA_ENABLE (set by the caller) gates streaming.
run_workload_once() {
    local RES="$1" scratch="/tmp/dm_${WL_TYPE}_$$_$RANDOM" dlib; dlib="$(darshan_lib)"
    connector_env "$GROUP"; darshan_env; workload_env
    local cmd=()
    case "$WL_TYPE" in
        c)         cmd=(./workloads/c/mofka_forward_smoke "$scratch") ;;
        python-ml) cmd=("$PY" workloads/python-ml/train.py "$scratch") ;;
        mpi)       cmd=(./workloads/mpi/mofka_forward_mpiio "$scratch") ;;
        dlio)      # DLIO from its isolated venv; generate_data only (real POSIX writes, no slow
                   # TF train loop). num_files scales with WL_EVENTS. Mirrors job.sh dlio case.
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
    local pre=()
    if [[ "$ARM_MODE" == none ]]; then
        pre=("${WORKLOAD_ENV[@]}")                       # no LD_PRELOAD: no Darshan at all
    else
        pre=(DARSHAN_LOGPATH="$RES" LD_PRELOAD="$dlib" "${CONNECTOR_ENV[@]}" "${DARSHAN_ENV[@]}" "${WORKLOAD_ENV[@]}")
    fi
    set +e
    # Launcher is profile-guarded via mpi_launch (env/common.sh): PALS mpiexec on polaris,
    # OpenMPI mpirun on lcrc. The old hardcoded mpirun/mpiexec+--mca flags ERROR under PALS.
    # A single local rank on the head node (non-mpi) needs no launcher (fast path).
    if [[ "$WL_PLACEMENT" == separate && "$WL_NODE" != "$SRV_NODE" ]]; then
        local estr="${pre[*]}"
        mpi_launch "$WL_TASKS" "$WL_TASKS" "$WL_HOSTFILE"
        "${MPI_LAUNCH[@]}" bash -lc \
          "cd '$ROOT' && source env/workload.sh >/dev/null 2>&1 && env $estr ${cmd[*]}" \
          > "$RES/workload.out" 2> "$RES/workload.err"
    elif [[ "$WL_TASKS" -gt 1 || "$WL_TYPE" == mpi ]]; then
        mpi_launch "$WL_TASKS" "$WL_TASKS" "$WL_HOSTFILE"
        "${MPI_LAUNCH[@]}" env "${pre[@]}" "${cmd[@]}" > "$RES/workload.out" 2> "$RES/workload.err"
    else
        env "${pre[@]}" "${cmd[@]}" > "$RES/workload.out" 2> "$RES/workload.err"
    fi
    local rc=$?
    return $rc
}

# ---- metric extractors (from workload.err / workload.out) ----
push_stats() {  # $1=workload.err -> "count mean_us median_us"
    awk '/darshan-mofka\[timing\] send/ {v[n++]=$(NF-1)}
         END{ if(n==0){print "0 0 0"; exit}
              asort(v); s=0; for(i=1;i<=n;i++)s+=v[i];
              m=(n%2)?v[(n+1)/2]:(v[n/2]+v[n/2+1])/2;
              printf "%d %.3f %.3f\n", n, s/n, m }' "$1" 2>/dev/null || echo "0 0 0"
}
timing_us() { # $1=workload.err $2=phase(initialize|finalize) -> us or NA
    local v; v=$(grep "darshan-mofka\[timing\] $2 " "$1" 2>/dev/null | tail -1 | awk '{print $(NF-1)}')
    echo "${v:-NA}"
}
nevents_of() { # $1=workload.out -> integer or NA
    local v; v=$(grep -oE 'TOTAL~[0-9]+' "$1" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
    echo "${v:-NA}"
}

# RESBASE name must reflect the ACTUAL study workload(s). results_dir_name()'s workload_tag
# reads $WORKLOAD, but submit.sh forwards only STUDY_WORKLOADS for a study run (not WORKLOAD),
# so $WORKLOAD was unset here and _cfg_env fell back to the config default 'c' -- an mpi-only
# study got dir-named ...C..., and since RESBASE is rm -rf'd just below, a later real c run at
# the same topology would clobber it. Build the workload tag from STUDY_WORKLOADS instead
# (joined with + for a multi-workload study). BX 2026-07-27
export WORKLOAD="${STUDY_WORKLOADS%% *}"        # first study wl -> valid WL_* for topology tag
_study_wl_tag=$(printf '%s' "$STUDY_WORKLOADS" | tr ' ' '+' | tr -d '-' | tr '[:lower:]' '[:upper:]')
_topo_tag=$(results_dir_name); _topo_tag="${_topo_tag#*_}"   # drop the (config-default) workload_tag
RESBASE="$ROOT/results/OVERHEAD_STUDY_${_study_wl_tag}_${_topo_tag}"
rm -rf "$RESBASE"; mkdir -p "$RESBASE"
CSV="$RESBASE/summary.csv"
echo "workload,arm,rep,wall_s,init_us,finalize_us,pushes,events,push_mean_us,push_median_us" > "$CSV"

ARM_STREAM_NAME="Streaming_${SRV_PARTITIONS}part-${SRV_PART_TYPE}_${WL_NODES}node_${WL_TASKS}task_${WL_BROKERS}broker-${WL_PLACEMENT}_${BRK_RPC_THREADS}rpcthread"

# one record row
record() { # $1=workload $2=arm $3=rep $4=RES $5=wall
    local sends mean med
    read -r sends mean med < <(push_stats "$4/workload.err")
    echo "$1,$2,$3,$5,$(timing_us "$4/workload.err" initialize),$(timing_us "$4/workload.err" finalize),$sends,$(nevents_of "$4/workload.out"),$mean,$med" >> "$CSV"
    echo "    $2 rep$3: wall=${5}s init=$(timing_us "$4/workload.err" initialize)us finalize=$(timing_us "$4/workload.err" finalize)us pushes=$sends push_mean=${mean}us push_med=${med}us"
}

# ONE consumer for the whole job (a 2nd start_consumer races on teardown). Started
# before any streaming; idles during the no-stream arms; drains the streaming arm.
RUN_DIR="$ROOT/server/_flowcept_run"; rm -rf "$RUN_DIR"
start_consumer "$RUN_DIR" "$GROUP" || die "consumer failed"
FIDELITY_DONE=0

for w in $STUDY_WORKLOADS; do
    export WORKLOAD="$w"; load_run_config     # WL_TYPE follows WORKLOAD via _cfg_env
    say "workload: $w  (events=$STUDY_EVENTS, reps=$STUDY_REPS)"
    compile_workload "$w"
    WDIR="$RESBASE/$w"; mkdir -p "$WDIR"

    # --- arm 1: no Darshan, no Mofka ---
    ARM_MODE=none; unset DARSHAN_MOFKA_ENABLE
    for rep in $(seq 1 "$STUDY_REPS"); do
        RES="$WDIR/Baseline_nodarshan_nomofka_RUN$rep"; mkdir -p "$RES"
        t0=$(now); run_workload_once "$RES"; t1=$(now)
        record "$w" "Baseline_nodarshan_nomofka" "$rep" "$RES" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f",b-a}')"
    done

    # --- arm 2: Darshan runtime only (no streaming) ---
    ARM_MODE=runtime; export DARSHAN_MOFKA_ENABLE=0
    for rep in $(seq 1 "$STUDY_REPS"); do
        RES="$WDIR/Enable_darshan_runtimeonly_RUN$rep"; mkdir -p "$RES"
        t0=$(now); run_workload_once "$RES"; t1=$(now)
        record "$w" "Enable_darshan_runtimeonly" "$rep" "$RES" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f",b-a}')"
    done

    # --- arm 3: full streaming (consumer draining) ---
    ARM_MODE=stream; export DARSHAN_MOFKA_ENABLE=1
    for rep in $(seq 1 "$STUDY_REPS"); do
        RES="$WDIR/${ARM_STREAM_NAME}_RUN$rep"; mkdir -p "$RES"
        t0=$(now); run_workload_once "$RES"; t1=$(now)
        record "$w" "$ARM_STREAM_NAME" "$rep" "$RES" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f",b-a}')"

        # fidelity: reconstruct+compare the first streaming rep once (db is clean then)
        if [[ "$FIDELITY_DONE" == 0 ]]; then
            FIDELITY_DONE=1
            say "fidelity check ($w, first streaming rep)"
            EVJSONL="$RES/events.jsonl"
            vsends=$(grep -c 'darshan-mofka\[timing\] send' "$RES/workload.err" 2>/dev/null || echo 0)
            n=0; for i in $(seq 1 40); do
                "$PY" "$ROOT/Client/export_jsonl.py" 127.0.0.1 "$SRV_MONGO_DB" \
                    --mongo-port "$SRV_MONGO_PORT" > "$EVJSONL" 2>/dev/null || true
                n=$(wc -l < "$EVJSONL" 2>/dev/null || echo 0)
                [ "$n" -ge "$vsends" ] && break; sleep 3
            done
            echo "exported $n events (sends=$vsends)"
            # Reconstruct one .darshan per process into streamed/, collect the native per-process
            # logs into native/ (EXCLUDING streamed/ + native/ so the reconstruct output can't leak
            # back in as native -> duplicate-pid ERROR), then run the SAME strict validator job.sh
            # uses: per-process/per-record EXACT integer-counter compare (perproc; mpi mode aggregates
            # per-rank the way Darshan's reduction does). No weak op-total rubber stamp. (BX 2026-07-27)
            STREAMED_DIR="$RES/streamed"; NATIVE_DIR="$RES/native"
            rm -rf "$STREAMED_DIR" "$NATIVE_DIR"; mkdir -p "$STREAMED_DIR" "$NATIVE_DIR"
            if "$B/darshan-mofka-reconstruct" "$EVJSONL" "$STREAMED_DIR" 2>/dev/null \
               && ls "$STREAMED_DIR"/*.darshan >/dev/null 2>&1; then
                mapfile -t NATIVE_LOGS < <(find "$RES" "$DARSHAN_LOGPATH" -name '*.darshan' \
                    ! -path "$STREAMED_DIR/*" ! -path "$NATIVE_DIR/*" -newermt '-30 min' 2>/dev/null | sort)
                for nl in "${NATIVE_LOGS[@]}"; do cp "$nl" "$NATIVE_DIR/"; done
                cmp_mode="perproc"; [[ "$WL_TYPE" == "mpi" ]] && cmp_mode="mpi"
                ( cd "$RES" && "$PY" "$ROOT/workloads/strict_compare.py" streamed native "$cmp_mode" ) \
                    | tee "$RES/compare.txt" || true
                ONE_REC="$(ls "$STREAMED_DIR"/*.darshan 2>/dev/null | head -1)"
                [[ -n "$ONE_REC" ]] && "$B/darshan-parser" "$ONE_REC" 2>/dev/null | grep -iE '^# exe|^# mount entry' | head
            fi
        fi
    done
done

# start_consumer (lib/run.sh) fills the CONSUMER_PIDS array, never a singular
# CONSUMER_PID -- referencing the singular here crashed under `set -u` before the
# report table below was written. Tear down every consumer pid (guarded for the
# case start_consumer never ran).
for _cp in "${CONSUMER_PIDS[@]:-}"; do kill "$_cp" 2>/dev/null; wait "$_cp" 2>/dev/null || true; done

# --- report: study parameters + per-arm metrics table ---
say "report"
{
  echo "OVERHEAD STUDY -- $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo now)"
  echo
  echo "STUDY PARAMETERS (constant across arms)"
  echo "  topology     : nodes=$WL_NODES tasks=$WL_TASKS placement=$WL_PLACEMENT brokers=$WL_BROKERS"
  echo "  broker       : partitions=$SRV_PARTITIONS type=$SRV_PART_TYPE rpc_threads=$BRK_RPC_THREADS progress_thread=$BRK_PROGRESS transport=$SRV_PROTOCOL"
  echo "  workload     : events=$STUDY_EVENTS reps=$STUDY_REPS variations=[$STUDY_WORKLOADS]"
  echo
} > "$RESBASE/report.txt"
"$PY" - "$CSV" <<'PY' | tee -a "$RESBASE/report.txt"
import sys, csv, statistics as st
rows=list(csv.DictReader(open(sys.argv[1])))
def num(x):
    try: return float(x)
    except: return None
def vals_of(rs, key):
    return [num(r[key]) for r in rs if num(r[key]) is not None]
def agg(rs, key):
    vals=vals_of(rs, key)
    return st.mean(vals) if vals else None
def sd(rs, key):
    # sample stdev over reps; 0.000 for n<2 so a single rep prints cleanly (not NA)
    vals=vals_of(rs, key)
    return st.stdev(vals) if len(vals)>1 else (0.0 if vals else None)
def fmt(x, d=3):
    return "NA" if x is None else f"{x:.{d}f}"
wls=[]
for r in rows:
    if r["workload"] not in wls: wls.append(r["workload"])
# wall_s reported as mean +/- sample-stdev over reps (deliverable Table 1).
hdr=f'{"arm":<52}{"reps":>5}{"wall_s":>10}{"wall_sd":>9}{"init_us":>12}{"final_us":>12}{"pushes":>9}{"events":>9}{"push_mean":>11}{"push_med":>10}'
for w in wls:
    print(f"\n=== workload: {w} ===")
    print(hdr); print("-"*len(hdr))
    arms=[]
    for r in rows:
        if r["workload"]==w and r["arm"] not in arms: arms.append(r["arm"])
    base=None
    for a in arms:
        rs=[r for r in rows if r["workload"]==w and r["arm"]==a]
        wall=agg(rs,"wall_s"); wsd=sd(rs,"wall_s"); ini=agg(rs,"init_us"); fin=agg(rs,"finalize_us")
        pu=agg(rs,"pushes"); ev=agg(rs,"events"); pm=agg(rs,"push_mean_us"); pmed=agg(rs,"push_median_us")
        if base is None: base=wall
        print(f'{a:<52}{len(rs):>5}{fmt(wall):>10}{fmt(wsd):>9}{fmt(ini,1):>12}{fmt(fin,1):>12}'
              f'{("NA" if pu is None else str(int(pu))):>9}{("NA" if ev is None else str(int(ev))):>9}'
              f'{fmt(pm):>11}{fmt(pmed):>10}')
    # derived overhead vs the no-Darshan baseline (mean +/- stdev of wall)
    def wl_stats(sub):
        for a in arms:
            if sub in a:
                rs=[r for r in rows if r["workload"]==w and r["arm"]==a]
                return agg(rs,"wall_s"), sd(rs,"wall_s")
        return None, None
    b,bsd=wl_stats("nodarshan"); d,dsd=wl_stats("runtimeonly"); s,ssd=wl_stats("Streaming")
    if b is not None: print(f"  wall mean+/-sd: baseline={fmt(b)}+/-{fmt(bsd)}s"
                            f"{'' if d is None else f'  runtimeonly={fmt(d)}+/-{fmt(dsd)}s'}"
                            f"{'' if s is None else f'  streaming={fmt(s)}+/-{fmt(ssd)}s'}")
    print("  derived overhead (mean wall):")
    if b and d: print(f"    Darshan runtime    : {(d-b)/b*100:+.1f}%  ({d-b:+.3f}s vs no-Darshan)")
    if d and s: print(f"    streaming (vs Darshan): {(s-d)/d*100:+.1f}%  ({s-d:+.3f}s)")
    if b and s: print(f"    streaming (vs none)   : {(s-b)/b*100:+.1f}%  ({s-b:+.3f}s total)")
print(f"\nfull CSV: {sys.argv[1]}")
PY

say "STUDY DONE"
echo "results: $RESBASE"
