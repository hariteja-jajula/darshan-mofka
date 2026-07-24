#!/bin/bash
# workloads/overhead_sweep.sh -- sweep streaming configurations in ONE allocation.
#
# Two reference arms are run once (no broker needed):
#   Baseline_nodarshan_nomofka   - workload, no LD_PRELOAD
#   Enable_darshan_runtimeonly   - Darshan LD_PRELOAD, ENABLE=0 (records, no stream)
# Then each streaming CONFIG below gets a FRESH broker + a FRESH consumer on its own
# mongo port/dbpath (so a slow-dying mongod never collides with the next config), and
# is measured for wall / init / finalize / pushes / per-push latency. One-knob-at-a-time
# from a baseline (1 partition, memory, separate, 1 broker, 1 task, 4 rpc threads).
#
# Submit:
#   RUN_SCRIPT=workloads/overhead_sweep.sh STUDY_EVENTS=5000 STUDY_REPS=2 \
#     PBS_ACCOUNT=<acct> bash submit.sh
# Needs a 2-node allocation (workload.config topology.nodes: 2) for separate/per-node.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
SKIP_BUILD="${SKIP_BUILD:-0}"
say()  { printf '\n########## %s ##########\n' "$*"; }
die()  { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }
now()  { date +%s.%N; }

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
         MPICC="$(command -v mpicc || echo "$CC")"
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
    if [[ "$WL_PLACEMENT" == separate && "$WL_NODE" != "$SRV_NODE" ]]; then
        local estr="${pre[*]}"
        mpirun -n "$WL_TASKS" --host "$WL_NODE" bash -lc \
          "cd '$ROOT' && source env/workload.sh >/dev/null 2>&1 && env $estr ${cmd[*]}" \
          > "$RES/workload.out" 2> "$RES/workload.err"
    elif [[ "$WL_TASKS" -gt 1 || "$WL_TYPE" == mpi ]]; then
        mpiexec --oversubscribe -n "$WL_TASKS" --mca pml ob1 --mca btl tcp,self \
          env "${pre[@]}" "${cmd[@]}" > "$RES/workload.out" 2> "$RES/workload.err"
    else
        env "${pre[@]}" "${cmd[@]}" > "$RES/workload.out" 2> "$RES/workload.err"
    fi
    return $?
}
push_stats() { awk '/darshan-mofka\[timing\] send/ {v[n++]=$(NF-1)} END{ if(n==0){print "0 0 0"; exit} asort(v); s=0; for(i=1;i<=n;i++)s+=v[i]; m=(n%2)?v[(n+1)/2]:(v[n/2]+v[n/2+1])/2; printf "%d %.3f %.3f\n", n, s/n, m }' "$1" 2>/dev/null || echo "0 0 0"; }
timing_us() { local v; v=$(grep "darshan-mofka\[timing\] $2 " "$1" 2>/dev/null | tail -1 | awk '{print $(NF-1)}'); echo "${v:-NA}"; }

RESBASE="$ROOT/results/OVERHEAD_SWEEP_${WL_TYPE}_${NNODES}node"
rm -rf "$RESBASE"; mkdir -p "$RESBASE"
CSV="$RESBASE/summary.csv"
echo "config,rep,wall_s,init_us,finalize_us,pushes,push_mean_us,push_median_us" > "$CSV"

record() { # $1=config $2=rep $3=RES $4=wall
    local sends mean med; read -r sends mean med < <(push_stats "$3/workload.err")
    echo "$1,$2,$4,$(timing_us "$3/workload.err" initialize),$(timing_us "$3/workload.err" finalize),$sends,$mean,$med" >> "$CSV"
    echo "    $1 rep$2: wall=${4}s init=$(timing_us "$3/workload.err" initialize)us final=$(timing_us "$3/workload.err" finalize)us pushes=$sends push_mean=${mean}us push_med=${med}us"
}

# ---- reference arms (no broker/consumer) ----
# references don't stream; give GROUP a harmless value so connector_env (called in
# run_workload_once) doesn't trip set -u before the per-config broker sets it. Run
# them on the same node the separate-placement streaming baseline uses, for a fair
# wall-time comparison.
GROUP="${GROUP:-}"
WL_NODE="${NODELIST[1]:-${NODELIST[0]}}"
say "reference: Baseline_nodarshan_nomofka x$STUDY_REPS"
ARM_MODE=none; unset DARSHAN_MOFKA_ENABLE
for rep in $(seq 1 "$STUDY_REPS"); do
    RES="$RESBASE/Baseline_nodarshan_nomofka_RUN$rep"; mkdir -p "$RES"
    t0=$(now); run_workload_once "$RES"; t1=$(now); record "Baseline_nodarshan_nomofka" "$rep" "$RES" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f",b-a}')"
done
say "reference: Enable_darshan_runtimeonly x$STUDY_REPS"
ARM_MODE=runtime; export DARSHAN_MOFKA_ENABLE=0
for rep in $(seq 1 "$STUDY_REPS"); do
    RES="$RESBASE/Enable_darshan_runtimeonly_RUN$rep"; mkdir -p "$RES"
    t0=$(now); run_workload_once "$RES"; t1=$(now); record "Enable_darshan_runtimeonly" "$rep" "$RES" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f",b-a}')"
done

# ---- streaming config sweep ----
# each entry: PARTITIONS RPC_THREADS PARTTYPE BROKERS PLACEMENT TASKS
CONFIGS=(
  "1 4 memory 1 separate 1"     # baseline
  "2 4 memory 1 separate 1"     # partitions
  "4 4 memory 1 separate 1"
  "1 1 memory 1 separate 1"     # rpc threads
  "1 2 memory 1 separate 1"
  "1 8 memory 1 separate 1"
  "1 4 memory 1 colocated 1"    # placement
  "1 4 memory per-node 1"       # broker per node
  "1 4 memory 1 separate 2"     # tasks (oversubscribe)
  "1 4 memory 1 separate 4"
)
[[ "$NNODES" -ge 2 ]] || echo "WARN: <2 nodes; separate/per-node fall back to one node"

ARM_MODE=stream; export DARSHAN_MOFKA_ENABLE=1
FIDELITY_DONE=0; idx=0
for cfg in "${CONFIGS[@]}"; do
    read -r P RPC PT BRK PLACE TASKS <<<"$cfg"
    idx=$((idx+1))
    export PARTITIONS="$P" RPC_THREAD_COUNT="$RPC" MOFKA_PARTITION_TYPE="$PT" BROKERS="$BRK" PLACEMENT="$PLACE" TASKS="$TASKS"
    export MONGO_PORT="$((27017 + idx))"   # unique port per config -> no restart race
    load_run_config
    NAME="Streaming_${P}part-${PT}_${BRK}broker-${PLACE}_${TASKS}task_${RPC}rpcthread"
    say "config $idx/${#CONFIGS[@]}: $NAME"

    # workload node per placement
    WL_NODE="$SRV_NODE"; [[ "$PLACE" == separate ]] && WL_NODE="${NODELIST[1]:-${NODELIST[0]}}"
    NRANKS_BROKER=$([[ "$BRK" == per-node ]] && echo "$NNODES" || echo 1)

    pkill -f 'bedrock ' 2>/dev/null || true; sleep 2
    if ! start_broker "$RESBASE/_broker_$idx" "$NRANKS_BROKER"; then echo "  broker failed; skip"; continue; fi
    RUN_DIR="$RESBASE/_consumer_$idx"; rm -rf "$RUN_DIR"
    if ! start_consumer "$RUN_DIR" "$GROUP"; then echo "  consumer failed; skip"; kill "$BROKER_PID" 2>/dev/null; continue; fi

    for rep in $(seq 1 "$STUDY_REPS"); do
        RES="$RESBASE/${NAME}_RUN$rep"; mkdir -p "$RES"
        t0=$(now); run_workload_once "$RES"; t1=$(now); record "$NAME" "$rep" "$RES" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f",b-a}')"
        if [[ "$FIDELITY_DONE" == 0 ]]; then
            FIDELITY_DONE=1; EVJSONL="$RES/events.jsonl"
            vs=$(grep -c 'darshan-mofka\[timing\] send' "$RES/workload.err" 2>/dev/null || echo 0)
            nn=0; for i in $(seq 1 40); do
                "$PY" "$ROOT/Client/export_jsonl.py" 127.0.0.1 "$SRV_MONGO_DB" --mongo-port "$SRV_MONGO_PORT" > "$EVJSONL" 2>/dev/null || true
                nn=$(wc -l < "$EVJSONL" 2>/dev/null || echo 0); [ "$nn" -ge "$vs" ] && break; sleep 3
            done
            if "$B/darshan-mofka-reconstruct" "$EVJSONL" "$RES/partial.darshan" 2>/dev/null; then
                NATIVE="$(find "$RES" "$DARSHAN_LOGPATH" -name '*.darshan' ! -name 'partial.darshan' -newermt '-30 min' 2>/dev/null | sort | tail -1)"
                "$B/darshan-parser" --show-incomplete "$RES/partial.darshan" | grep -E "^(POSIX|STDIO|MPIIO)" | sort > "$RES/r.txt" || true
                [[ -n "$NATIVE" ]] && "$B/darshan-parser" --show-incomplete "$NATIVE" | grep -E "^(POSIX|STDIO|MPIIO)" | sort > "$RES/n.txt" || true
                if diff -q "$RES/r.txt" "$RES/n.txt" >/dev/null 2>&1; then echo "  fidelity VERDICT: PASS"; else echo "  fidelity VERDICT: check $RES"; fi
            fi
        fi
    done
    kill "$CONSUMER_PID" 2>/dev/null; wait "$CONSUMER_PID" 2>/dev/null || true
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
def fmt(x,d=3): return "NA" if x is None else f"{x:.{d}f}"
cfgs=[]
for r in rows:
    if r["config"] not in cfgs: cfgs.append(r["config"])
base=None
for c in cfgs:
    if "nodarshan" in c: base=agg([r for r in rows if r["config"]==c],"wall_s")
hdr=f'{"config":<48}{"reps":>5}{"wall_s":>9}{"init_us":>11}{"final_us":>11}{"pushes":>8}{"push_mean":>11}{"push_med":>10}{"vs_base":>9}'
print(hdr); print("-"*len(hdr))
for c in cfgs:
    rs=[r for r in rows if r["config"]==c]
    wall=agg(rs,"wall_s"); ov=(f"{(wall-base)/base*100:+.1f}%" if (base and wall) else "NA")
    print(f'{c:<48}{len(rs):>5}{fmt(wall):>9}{fmt(agg(rs,"init_us"),1):>11}{fmt(agg(rs,"finalize_us"),1):>11}'
          f'{("NA" if agg(rs,"pushes") is None else str(int(agg(rs,"pushes")))):>8}{fmt(agg(rs,"push_mean_us")):>11}{fmt(agg(rs,"push_median_us")):>10}{ov:>9}')
print(f"\nfull CSV: {sys.argv[1]}")
PY
say "SWEEP DONE"; echo "results: $RESBASE"
