#!/bin/bash
# workloads/overhead_buffer_sweep.sh -- sweep the ASYNC BUFFER knobs in ONE allocation.
#
# Motivation (#22): with the async off-hot-path connector (darshan-mofka.c), the app-thread
# push is sub-us and the ring never fills, so ALL residual streaming overhead is the finalize
# DRAIN TAIL (join the drain thread(s) + flush the Mofka producer). The lever on that tail is
# Mofka's OWN batching (DARSHAN_MOFKA_BATCH / MAX_BATCHES -> diaspora_producer_create, dm.c:279)
# and the number of drain threads (DARSHAN_MOFKA_DRAIN_THREADS). QUEUE_DEPTH only matters if the
# ring ever fills (it doesn't at these rates) -- swept once to confirm no drops, not for speed.
#
# Topology is FIXED at the baseline (1 partition, memory, 1 broker, separate, 1 task, RPC from
# config) so the ONLY variable is the buffer knobs. Two reference arms run once (no broker), then
# each BUFCFG gets a FRESH broker + consumer on its own mongo port/dbpath. Metric: does a larger
# BATCH / extra drain thread shrink finalize_us (the tail) and thus wall, WITHOUT drops or a
# fidelity regression.
#
# Submit (mpi has the largest tail -> best signal; ~10-min via STUDY_EVENTS):
#   RUN_SCRIPT=workloads/overhead_buffer_sweep.sh WORKLOAD=mpi STUDY_EVENTS=500000 STUDY_REPS=1 \
#     DARSHAN_MOFKA_ASYNC=1 DARSHAN_MOFKA_DROP_POLICY=block PBS_ACCOUNT=<acct> bash submit.sh
# Needs a 2-node allocation (workload.config topology.nodes: 2) for separate placement.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
SKIP_BUILD="${SKIP_BUILD:-0}"
say()  { printf '\n########## %s ##########\n' "$*"; }
die()  { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }
now()  { date +%s.%N; }

# assert_run_ok $rc $RES $label -- fail LOUDLY when a MEASURED run did not
# actually succeed, instead of tabulating a crashed run (non-zero rc or a fatal
# stderr marker like the dlio "after finalizing MPICH" abort) as valid overhead.
# Reference arms use this directly. The warm-up stays best-effort. (BX 2026-07-27)
assert_run_ok() { # $1=rc $2=RES $3=label
    local rc="$1" RES="$2" label="$3" err="$2/workload.err"
    if [[ "$rc" -ne 0 ]]; then
        [[ -f "$err" ]] && { echo "---- last 25 lines of $err ----" >&2; tail -25 "$err" >&2; }
        die "workload run FAILED (rc=$rc) for '$label' [$RES] -- refusing to tabulate a crashed run as overhead"
    fi
    if [[ -f "$err" ]] && grep -Eq 'after finalizing MPICH|Assertion .* failed|Fatal error in|core dumped|Segmentation fault' "$err"; then
        echo "---- fatal marker in $err ----" >&2; grep -En 'after finalizing MPICH|Assertion .* failed|Fatal error in|core dumped|Segmentation fault' "$err" | tail -10 >&2
        die "workload run hit a FATAL marker (rc was 0 but stderr shows a crash) for '$label' [$RES]"
    fi
}

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
STUDY_REPS="${STUDY_REPS:-2}"
export EVENTS="$STUDY_EVENTS"
export DARSHAN_MOFKA_TIMING=1
echo "sweep: workload=$WL_TYPE events=$STUDY_EVENTS reps=$STUDY_REPS"

# --- build ---
if [[ "$SKIP_BUILD" = "1" && -e "$(darshan_lib 2>/dev/null)" ]]; then
    say "2. build (SKIP_BUILD=1)"
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
    ( cd darshan/darshan-util
      if [[ ! -f _build_util/Makefile ]]; then
          ( cd .. && ./prepare.sh ); mkdir -p _build_util
          ( cd _build_util && ../configure --prefix="$PWD/../install" )
      fi
      ( cd _build_util && make -j4 && make install ) ) || die "darshan-util build failed"
fi
B="$ROOT/darshan/darshan-util/install/bin"
[[ -x "$B/darshan-parser" && -x "$B/darshan-mofka-reconstruct" ]] || die "darshan-util tools missing"

MONGOD="${MONGOD:-$(command -v mongod || true)}"; export MONGOD
[[ -x "$MONGOD" ]] || die "mongod not found"

mapfile -t NODELIST < <(sort -u "${PBS_NODEFILE:-/dev/null}" 2>/dev/null)
[[ ${#NODELIST[@]} -ge 1 ]] || NODELIST=("$(hostname)")
NNODES="${#NODELIST[@]}"; SRV_NODE="${NODELIST[0]}"
say "nodes=$NNODES broker-home=$SRV_NODE"

case "$WL_TYPE" in
    c)   "$CC" -O2 workloads/c/mofka_forward_smoke.c -o workloads/c/mofka_forward_smoke || die "compile failed" ;;
    mpi) DARSHAN_MPI=1 ./build.sh >/dev/null 2>&1 || true
         # On Polaris the MPI+GCC compiler is the craype `cc` wrapper (links cray-mpich);
         # bare `mpicc` is the PrgEnv-nvidia wrapper (wrong). Mirror overhead_study.sh:111-121.
         if [[ "${ENV_PROFILE:-}" == polaris ]]; then
             MPICC="${MPI_WL_CC:-cc}"
         else
             MPICC="${MPI_WL_CC:-$(command -v mpicc || echo "$CC")}"
         fi
         "$MPICC" -O2 workloads/mpi/mofka_forward_mpiio.c -o workloads/mpi/mofka_forward_mpiio || die "compile failed" ;;
esac

run_workload_once() {  # $1=RES ; uses ARM_MODE + WL_* globals
    local RES="$1" scratch="/tmp/dm_${WL_TYPE}_$$_$RANDOM" dlib; dlib="$(darshan_lib)"
    connector_env "$GROUP"; darshan_env; workload_env
    local cmd=()
    case "$WL_TYPE" in
        c)         cmd=(./workloads/c/mofka_forward_smoke "$scratch") ;;
        python-ml) cmd=("$PY" workloads/python-ml/train.py "$scratch") ;;
        mpi)       cmd=(./workloads/mpi/mofka_forward_mpiio "$scratch") ;;
    esac
    local pre=()
    if [[ "$ARM_MODE" == none ]]; then pre=("${WORKLOAD_ENV[@]}")
    else pre=(DARSHAN_LOGPATH="$RES" LD_PRELOAD="$dlib" "${CONNECTOR_ENV[@]}" "${DARSHAN_ENV[@]}" "${WORKLOAD_ENV[@]}"); fi
    set +e
    # Profile-guarded launcher (env/common.sh mpi_launch): PALS mpiexec on polaris, OpenMPI
    # on lcrc. WL_NODE changes per swept config, so (re)write the workload hostfile here --
    # bare hostname for PALS (it parses "HOST slots=N" as one hostname), "HOST slots=N" for
    # OpenMPI. The old hardcoded mpirun/mpiexec --mca flags ERROR under PALS.
    local WL_HOSTFILE="$ROOT/server/_sweep_wl_hostfile"
    if [[ "$ENV_PROFILE" == polaris ]]; then
        printf '%s\n' "$WL_NODE" > "$WL_HOSTFILE"
    else
        printf '%s slots=%s\n' "$WL_NODE" "$WL_TASKS" > "$WL_HOSTFILE"
    fi
    if [[ "$WL_PLACEMENT" == separate && "$WL_NODE" != "$SRV_NODE" ]]; then
        local estr="${pre[*]}"
        mpi_launch "$WL_TASKS" "$WL_TASKS" "$WL_HOSTFILE"
        "${MPI_LAUNCH[@]}" bash -lc \
          "cd '$ROOT' && source env/workload.sh >/dev/null 2>&1 && env $estr ${cmd[*]}" \
          > "$RES/workload.out" 2> "$RES/workload.err"
    elif [[ "$WL_TASKS" -gt 1 || "$WL_TYPE" == mpi || "$WL_TYPE" == dlio ]]; then  # dlio=MPI app, needs launcher even at 1 rank (BX 2026-07-27)
        mpi_launch "$WL_TASKS" "$WL_TASKS" "$WL_HOSTFILE"
        "${MPI_LAUNCH[@]}" env "${pre[@]}" "${cmd[@]}" > "$RES/workload.out" 2> "$RES/workload.err"
    else
        env "${pre[@]}" "${cmd[@]}" > "$RES/workload.out" 2> "$RES/workload.err"
    fi
    return $?
}
push_stats() { awk '/darshan-mofka\[timing\] send/ {v[n++]=$(NF-1)} END{ if(n==0){print "0 0 0"; exit} asort(v); s=0; for(i=1;i<=n;i++)s+=v[i]; m=(n%2)?v[(n+1)/2]:(v[n/2]+v[n/2+1])/2; printf "%d %.3f %.3f\n", n, s/n, m }' "$1" 2>/dev/null || echo "0 0 0"; }
timing_us() { local v; v=$(grep "darshan-mofka\[timing\] $2 " "$1" 2>/dev/null | tail -1 | awk '{print $(NF-1)}'); echo "${v:-NA}"; }

RESBASE="$ROOT/results/OVERHEAD_BUFSWEEP_${WL_TYPE}_${NNODES}node"
rm -rf "$RESBASE"; mkdir -p "$RESBASE"
CSV="$RESBASE/summary.csv"
echo "config,rep,wall_s,init_us,finalize_us,pushes,push_mean_us,push_median_us,exported,drops" > "$CSV"

record() { # $1=config $2=rep $3=RES $4=wall [$5=exported]
    local sends mean med drops exp; read -r sends mean med < <(push_stats "$3/workload.err")
    # drops: the connector prints "darshan-mofka: dropped <N> events (ring full)" at finalize
    # (dm.c:608). With DROP_POLICY=block this must stay 0 (lossless); grep it so a silent loss
    # can't masquerade as a faster tail. Absent line => 0.
    drops=$(grep -oE 'dropped [0-9]+ events' "$3/workload.err" 2>/dev/null | tail -1 | grep -oE '[0-9]+' || echo 0); drops="${drops:-0}"
    exp="${5:-NA}"
    echo "$1,$2,$4,$(timing_us "$3/workload.err" initialize),$(timing_us "$3/workload.err" finalize),$sends,$mean,$med,$exp,$drops" >> "$CSV"
    echo "    $1 rep$2: wall=${4}s init=$(timing_us "$3/workload.err" initialize)us final=$(timing_us "$3/workload.err" finalize)us pushes=$sends push_med=${med}us drops=$drops exported=$exp"
}

# ---- reference arms (no broker/consumer) ----
# references don't stream; give GROUP a harmless value so connector_env (called in
# run_workload_once) doesn't trip set -u before the per-config broker sets it. Run
# them on the same node the separate-placement streaming baseline uses, for a fair
# wall-time comparison.
GROUP="${GROUP:-}"
WL_NODE="${NODELIST[1]:-${NODELIST[0]}}"

# warm-up (discarded): kill cold-start confounds (fresh /tmp, TF/py import cache, FS
# metadata) before the first TIMED rep. Runtime mode (ENABLE=0) records but does NOT
# stream (push-free), so it cannot pollute the mongo DB the fidelity check reads; no
# broker/consumer is up yet for the reference arms, which is fine -- ENABLE=0 never sends.
# BX 2026-07-27, cross-check a38eb94f.
ARM_MODE=runtime; export DARSHAN_MOFKA_ENABLE=0
WRES="$RESBASE/_warmup"; mkdir -p "$WRES"
say "warm-up (discarded): $WL_TYPE"
run_workload_once "$WRES" >/dev/null 2>&1 || true
rm -rf "$WRES"

say "reference: Baseline_nodarshan_nomofka x$STUDY_REPS"
ARM_MODE=none; unset DARSHAN_MOFKA_ENABLE
for rep in $(seq 1 "$STUDY_REPS"); do
    RES="$RESBASE/Baseline_nodarshan_nomofka_RUN$rep"; mkdir -p "$RES"
    t0=$(now); run_workload_once "$RES"; rc=$?; t1=$(now)
    assert_run_ok "$rc" "$RES" "Baseline_nodarshan_nomofka rep$rep"
    record "Baseline_nodarshan_nomofka" "$rep" "$RES" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f",b-a}')"
done
say "reference: Enable_darshan_runtimeonly x$STUDY_REPS"
ARM_MODE=runtime; export DARSHAN_MOFKA_ENABLE=0
for rep in $(seq 1 "$STUDY_REPS"); do
    RES="$RESBASE/Enable_darshan_runtimeonly_RUN$rep"; mkdir -p "$RES"
    t0=$(now); run_workload_once "$RES"; rc=$?; t1=$(now)
    assert_run_ok "$rc" "$RES" "Enable_darshan_runtimeonly rep$rep"
    record "Enable_darshan_runtimeonly" "$rep" "$RES" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f",b-a}')"
done

# ---- streaming config sweep ----
# Topology FIXED at the baseline; sweep ONLY the buffer knobs.
# each entry: BATCH MAX_BATCHES DRAIN_THREADS QUEUE_DEPTH
#   BATCH=0 => Mofka adaptive batching (current default); larger BATCH => fewer, bigger flushes.
#   The grid isolates one knob at a time from the async default (0 0 1 393216), then a combined
#   best-guess (large batch + 2 drain threads). QUEUE_DEPTH row confirms the ring never fills.
BUFCFGS=(
  "0 0 1 393216"        # async default (adaptive batch, 1 drain thread)   [baseline]
  "64 0 1 393216"       # batch size sweep
  "256 0 1 393216"
  "1024 0 1 393216"
  "4096 0 1 393216"
  "0 0 2 393216"        # drain threads: 2 (does parallel drain shrink the tail?)
  "0 0 4 393216"        # drain threads: 4
  "0 0 1 65536"         # queue depth DOWN: at ~125006 rec/rank (STUDY_EVENTS=50000, per-rank STEPS)
                        #   this ring FILLS -> block-mode backpressure (lossless, slower finalize).
                        #   This is the intended ring-fill probe; 393216/1048576 stay clear.
  "0 0 1 1048576"       # queue depth up (headroom; never fills)
  "1024 0 2 393216"     # combined: large batch + 2 drain threads (best-guess)
)
[[ "$NNODES" -ge 2 ]] || echo "WARN: <2 nodes; separate placement falls back to one node"

# fixed baseline topology for every buffer cell (separate placement -> workload on node 2)
export PARTITIONS=1 RPC_THREAD_COUNT="${RPC_THREAD_COUNT:-4}" MOFKA_PARTITION_TYPE=memory \
       BROKERS=1 PLACEMENT=separate TASKS="${TASKS:-1}"
WL_NODE="${NODELIST[1]:-${NODELIST[0]}}"
NRANKS_BROKER=1

ARM_MODE=stream; export DARSHAN_MOFKA_ENABLE=1
export DARSHAN_MOFKA_ASYNC="${DARSHAN_MOFKA_ASYNC:-1}"           # async is the point of this sweep
export DARSHAN_MOFKA_DROP_POLICY="${DARSHAN_MOFKA_DROP_POLICY:-block}"  # lossless: drops must stay 0
export DARSHAN_MOFKA_VERBOSE="${DARSHAN_MOFKA_VERBOSE:-1}"
FIDELITY_DONE=0; idx=0
for cfg in "${BUFCFGS[@]}"; do
    read -r BATCH MAXB DTH QD <<<"$cfg"
    idx=$((idx+1))
    export DARSHAN_MOFKA_BATCH="$BATCH" DARSHAN_MOFKA_MAX_BATCHES="$MAXB" \
           DARSHAN_MOFKA_DRAIN_THREADS="$DTH" DARSHAN_MOFKA_QUEUE_DEPTH="$QD"
    export MONGO_PORT="$((27017 + idx))"   # unique port per config -> no restart race
    load_run_config
    NAME="Buf_batch${BATCH}_maxb${MAXB}_drain${DTH}_qd${QD}"
    say "config $idx/${#BUFCFGS[@]}: $NAME"

    pkill -f 'bedrock ' 2>/dev/null || true; sleep 2
    if ! start_broker "$RESBASE/_broker_$idx" "$NRANKS_BROKER"; then echo "  broker failed; skip"; continue; fi
    RUN_DIR="$RESBASE/_consumer_$idx"; rm -rf "$RUN_DIR"
    if ! start_consumer "$RUN_DIR" "$GROUP"; then echo "  consumer failed; skip"; kill "$BROKER_PID" 2>/dev/null; continue; fi

    for rep in $(seq 1 "$STUDY_REPS"); do
        RES="$RESBASE/${NAME}_RUN$rep"; mkdir -p "$RES"
        t0=$(now); run_workload_once "$RES"; rc=$?; t1=$(now)
        # per-config streaming: a crashed run must NOT be tabulated as valid overhead.
        # Unlike the reference arms we skip the offending config (break its rep loop)
        # rather than kill the whole sweep, so the other configs' data survives.
        if [[ "$rc" -ne 0 ]] || { [[ -f "$RES/workload.err" ]] && grep -Eq 'after finalizing MPICH|Assertion .* failed|Fatal error in|core dumped|Segmentation fault' "$RES/workload.err"; }; then
            echo "  WARN: run FAILED (rc=$rc) for '$NAME' rep$rep -- skipping this config, NOT recording" >&2
            [[ -f "$RES/workload.err" ]] && tail -15 "$RES/workload.err" >&2
            break
        fi
        # per-cell delivery check: export this cell's own mongo DB and count docs. The whole
        # point of a buffer sweep is "does a bigger batch / fewer flushes silently lose events
        # at the broker?" -- so EVERY cell gets a delivered count, not just the fidelity cell.
        EVJSONL="$RES/events.jsonl"
        vs=$(grep -c 'darshan-mofka\[timing\] send' "$RES/workload.err" 2>/dev/null || echo 0)
        nn=0; for i in $(seq 1 40); do
            "$PY" "$ROOT/Client/export_jsonl.py" 127.0.0.1 "$SRV_MONGO_DB" --mongo-port "$SRV_MONGO_PORT" > "$EVJSONL" 2>/dev/null || true
            nn=$(wc -l < "$EVJSONL" 2>/dev/null || echo 0); [ "$nn" -ge "$vs" ] && break; sleep 3
        done
        record "$NAME" "$rep" "$RES" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f",b-a}')" "$nn"
        if [[ "$FIDELITY_DONE" == 0 ]]; then
            FIDELITY_DONE=1
            # Reconstruct per-process logs into streamed/, collect native into native/ (excluding
            # streamed/ + native/ so reconstruct output can't leak in as native), then run the SAME
            # strict validator job.sh/overhead_study.sh use: EXACT per-record integer-counter compare
            # (perproc; mpi mode aggregates per-rank). No weak diff/op-total rubber stamp. (BX 2026-07-27)
            if "$B/darshan-mofka-reconstruct" "$EVJSONL" "$RES/streamed" 2>/dev/null \
               && ls "$RES"/streamed/*.darshan >/dev/null 2>&1; then
                mkdir -p "$RES/native"
                mapfile -t NATIVE_LOGS < <(find "$RES" "$DARSHAN_LOGPATH" -name '*.darshan' \
                    ! -path "$RES/streamed/*" ! -path "$RES/native/*" -newermt '-30 min' 2>/dev/null | sort)
                for nl in "${NATIVE_LOGS[@]}"; do cp "$nl" "$RES/native/"; done
                cmp_mode="perproc"; [[ "$WL_TYPE" == "mpi" || "$WL_TYPE" == "dlio" ]] && cmp_mode="mpi"  # dlio = MPI mode (BX 2026-07-27)
                ( cd "$RES" && "$PY" "$ROOT/workloads/strict_compare.py" streamed native "$cmp_mode" ) \
                    | tee "$RES/compare.txt" || true
            fi
        fi
    done
    # CONSUMER_PIDS (array) is what start_consumer fills; singular CONSUMER_PID was
    # never set and tripped `set -u`. Kill every consumer pid (guarded).
    for _cp in "${CONSUMER_PIDS[@]:-}"; do kill "$_cp" 2>/dev/null; wait "$_cp" 2>/dev/null || true; done
    kill "$BROKER_PID" 2>/dev/null; wait "$BROKER_PID" 2>/dev/null || true
    pkill -f 'bedrock ' 2>/dev/null || true
done

# --- report ---
say "report"
"$PY" - "$CSV" <<'PY' | tee "$RESBASE/report.txt"
import sys, csv, statistics as st
rows=list(csv.DictReader(open(sys.argv[1])))
def num(x):
    try: return float(x)
    except: return None
def agg(rs,k):
    v=[num(r[k]) for r in rs if num(r[k]) is not None]; return st.mean(v) if v else None
def sd(rs,k):  # sample stdev (deliverable needs mean+/-sd); 0.0 for n=1
    v=[num(r[k]) for r in rs if num(r[k]) is not None]; return st.stdev(v) if len(v)>1 else (0.0 if v else None)
def fmt(x,d=3): return "NA" if x is None else f"{x:.{d}f}"
cfgs=[]
for r in rows:
    if r["config"] not in cfgs: cfgs.append(r["config"])
base=None
for c in cfgs:
    if "nodarshan" in c: base=agg([r for r in rows if r["config"]==c],"wall_s")
def ival(rs,k):
    v=[num(r.get(k)) for r in rs if num(r.get(k)) is not None]; return int(st.mean(v)) if v else None
hdr=f'{"config":<40}{"reps":>5}{"wall_s":>9}{"wall_sd":>9}{"final_us":>11}{"pushes":>9}{"exported":>9}{"drops":>7}{"push_med":>10}{"vs_base":>9}'
print(hdr); print("-"*len(hdr))
for c in cfgs:
    rs=[r for r in rows if r["config"]==c]
    wall=agg(rs,"wall_s"); ov=(f"{(wall-base)/base*100:+.1f}%" if (base and wall) else "NA")
    pu=ival(rs,"pushes"); ex=ival(rs,"exported"); dr=ival(rs,"drops")
    print(f'{c:<40}{len(rs):>5}{fmt(wall):>9}{fmt(sd(rs,"wall_s")):>9}{fmt(agg(rs,"finalize_us"),1):>11}'
          f'{("NA" if pu is None else str(pu)):>9}{("NA" if ex is None else str(ex)):>9}{("NA" if dr is None else str(dr)):>7}'
          f'{fmt(agg(rs,"push_median_us")):>10}{ov:>9}')
# integrity: any cell with drops>0 (block policy) or exported<pushes is a LOSS -> flag loudly
print()
for c in cfgs:
    rs=[r for r in rows if r["config"]==c]
    pu=ival(rs,"pushes"); ex=ival(rs,"exported"); dr=ival(rs,"drops")
    if dr and dr>0: print(f"  *** LOSS: {c} dropped {dr} events (block policy should never drop)")
    if pu and ex is not None and ex<pu: print(f"  *** UNDER-DELIVERED: {c} exported {ex} < pushes {pu}")
print(f"\nfull CSV: {sys.argv[1]}")
PY
say "SWEEP DONE"; echo "results: $RESBASE"
