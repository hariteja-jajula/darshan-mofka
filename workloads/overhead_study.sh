#!/bin/bash
# workloads/overhead_study.sh -- the connector overhead study, run inside ONE PBS
# allocation so both conditions share the same nodes (apples-to-apples).
#
# It answers two questions the demo needs numbers for:
#   1. Overhead: how much does streaming add over a runtime-only Darshan run?
#      -> A/B the same workload with DARSHAN_MOFKA_ENABLE=0 (baseline, no stream)
#         vs =1 (streaming), REPS each, comparing wall time.
#   2. Sustained average push cost: with connector timing on, the per-send latency
#      the connector reports across a long streaming run (mean/median us).
# The first streaming rep also drains + reconstructs + validates the log end to
# end (op-count VERDICT, exe/mounts, per-module HEATMAP) at study scale.
#
# Submit with:
#   RUN_SCRIPT=workloads/overhead_study.sh STUDY_EVENTS=10000 STUDY_REPS=3 \
#     PBS_ACCOUNT=<acct> bash submit.sh
# Topology (nodes/tasks/placement/brokers) still comes from workloads/workload.config;
# "1 server + 1 workload node" == nodes:2 placement:separate brokers:1.
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
load_run_config; WORKLOAD="$WL_TYPE"

STUDY_EVENTS="${STUDY_EVENTS:-$WL_EVENTS}"
STUDY_REPS="${STUDY_REPS:-${WL_REPS:-3}}"
export EVENTS="$STUDY_EVENTS"          # _cfg_env override so the workload scales
export DARSHAN_MOFKA_TIMING=1          # per-send latency -> workload.err
echo "study: workload=$WL_TYPE events=$STUDY_EVENTS reps=$STUDY_REPS"
echo "topology: nodes=$WL_NODES tasks=$WL_TASKS placement=$WL_PLACEMENT brokers=$WL_BROKERS"

# --- 2. build (same sequence as workloads/job.sh) ---
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

# --- 5. broker (once) ---
say "5. broker"
pkill -f 'bedrock ' 2>/dev/null || true; sleep 1
start_broker "$ROOT/server/_broker" "$NRANKS_BROKER" || die "broker failed"
trap 'kill "$BROKER_PID" 2>/dev/null; pkill -f "bedrock " 2>/dev/null || true' EXIT
echo "broker up | group $GROUP"

# --- 6. workload binary (once) ---
case "$WL_TYPE" in
    c)   "$CC" -O2 workloads/c/mofka_forward_smoke.c -o workloads/c/mofka_forward_smoke || die "compile failed" ;;
    mpi) DARSHAN_MPI=1 ./build.sh >/dev/null 2>&1 || true
         MPICC="$(command -v mpicc || echo "$CC")"
         "$MPICC" -O2 workloads/mpi/mofka_forward_mpiio.c -o workloads/mpi/mofka_forward_mpiio || die "compile failed" ;;
esac

# run the workload once into $1 (=RES); mirrors job.sh run_workload_once, but honors
# the current DARSHAN_MOFKA_ENABLE (set per condition below) and never aborts the study.
run_workload_once() {
    local RES="$1" scratch="/tmp/dm_${WL_TYPE}_$$_$RANDOM" dlib; dlib="$(darshan_lib)"
    connector_env "$GROUP"; darshan_env; workload_env
    local cmd=()
    case "$WL_TYPE" in
        c)         cmd=(./workloads/c/mofka_forward_smoke "$scratch") ;;
        python-ml) cmd=("$PY" workloads/python-ml/train.py "$scratch") ;;
        mpi)       cmd=(./workloads/mpi/mofka_forward_mpiio "$scratch") ;;
        *)         die "unknown workload '$WL_TYPE'" ;;
    esac
    local base=(DARSHAN_LOGPATH="$RES" LD_PRELOAD="$dlib" "${CONNECTOR_ENV[@]}" "${DARSHAN_ENV[@]}" "${WORKLOAD_ENV[@]}")
    set +e
    if [[ "$WL_PLACEMENT" == separate && "$WL_NODE" != "$SRV_NODE" ]]; then
        local estr="${CONNECTOR_ENV[*]} ${DARSHAN_ENV[*]} ${WORKLOAD_ENV[*]}"
        mpirun -n "$WL_TASKS" --host "$WL_NODE" bash -lc \
          "cd '$ROOT' && source env/workload.sh >/dev/null 2>&1 && env $estr DARSHAN_LOGPATH='$RES' LD_PRELOAD='$dlib' ${cmd[*]}" \
          > "$RES/workload.out" 2> "$RES/workload.err"
    elif [[ "$WL_TASKS" -gt 1 || "$WL_TYPE" == mpi ]]; then
        mpiexec --oversubscribe -n "$WL_TASKS" --mca pml ob1 --mca btl tcp,self \
          env "${base[@]}" "${cmd[@]}" > "$RES/workload.out" 2> "$RES/workload.err"
    else
        env "${base[@]}" "${cmd[@]}" > "$RES/workload.out" 2> "$RES/workload.err"
    fi
    local rc=$?           # errexit stays off for the whole study; rc is checked explicitly
    return $rc
}

# mean/median/count of the connector's per-send latency (us) from workload.err
push_stats() {  # $1=workload.err -> "count mean_us median_us"
    awk '/darshan-mofka\[timing\] send/ {v[n++]=$(NF-1)}
         END{ if(n==0){print "0 0 0"; exit}
              asort(v); s=0; for(i=1;i<=n;i++)s+=v[i];
              m=(n%2)?v[(n+1)/2]:(v[n/2]+v[n/2+1])/2;
              printf "%d %.3f %.3f\n", n, s/n, m }' "$1" 2>/dev/null || echo "0 0 0"
}

RESBASE="$ROOT/results/OVERHEAD_STUDY_$(results_dir_name)"
rm -rf "$RESBASE"; mkdir -p "$RESBASE"
CSV="$RESBASE/summary.csv"; echo "condition,rep,wall_s,sends,mean_push_us,median_push_us" > "$CSV"

# --- 7. baseline: runtime-only, no streaming, no consumer ---
say "7. baseline (DARSHAN_MOFKA_ENABLE=0) x$STUDY_REPS"
export DARSHAN_MOFKA_ENABLE=0
for rep in $(seq 1 "$STUDY_REPS"); do
    RES="$RESBASE/baseline_RUN$rep"; mkdir -p "$RES"
    t0=$(now); run_workload_once "$RES"; rc=$?; t1=$(now)
    wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')
    echo "  baseline rep$rep: wall=${wall}s rc=$rc"
    echo "baseline,$rep,$wall,0,0,0" >> "$CSV"
done

# --- 8. streaming: connector on; a FRESH consumer/db per rep so each rep's
#        events.jsonl holds exactly that rep (mirrors job.sh -- a single shared db
#        would accumulate all reps and make the op-count compare 3x the native). ---
say "8. streaming (DARSHAN_MOFKA_ENABLE=1) x$STUDY_REPS"
export DARSHAN_MOFKA_ENABLE=1
RUN_DIR="$ROOT/server/_flowcept_run"
LAST_RES=""
for rep in $(seq 1 "$STUDY_REPS"); do
    RES="$RESBASE/streaming_RUN$rep"; mkdir -p "$RES"; LAST_RES="$RES"
    rm -rf "$RUN_DIR"; start_consumer "$RUN_DIR" "$GROUP" || die "consumer failed"
    t0=$(now); run_workload_once "$RES"; rc=$?; t1=$(now)
    wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.3f", b-a}')
    read -r sends mean med < <(push_stats "$RES/workload.err")
    echo "  streaming rep$rep: wall=${wall}s sends=$sends mean_push=${mean}us median=${med}us rc=$rc"
    echo "streaming,$rep,$wall,$sends,$mean,$med" >> "$CSV"
    stop_consumer_verdict "$RUN_DIR" "$RES/ingest.txt" "$RES/events.jsonl"  # export+kill per rep
    echo "    exported: $(wc -l < "$RES/events.jsonl" 2>/dev/null || echo 0) events"
done

# --- 9. e2e validation from the last streaming rep (reconstruct + 1:1 compare) ---
say "9. end-to-end validation (last streaming rep)"
EVJSONL="$LAST_RES/events.jsonl"
echo "exported lines: $(wc -l < "$EVJSONL" 2>/dev/null || echo 0)"
PARTIAL="$LAST_RES/partial.darshan"
if "$B/darshan-mofka-reconstruct" "$EVJSONL" "$PARTIAL"; then
    NATIVE="$(find "$LAST_RES" "$DARSHAN_LOGPATH" -name '*.darshan' ! -name 'partial.darshan' -newermt '-30 min' 2>/dev/null | sort | tail -1)"
    "$B/darshan-parser" --show-incomplete "$PARTIAL" | grep -E "^(POSIX|STDIO|MPIIO)" | sort > "$LAST_RES/r.txt" || true
    [[ -n "$NATIVE" ]] && { cp "$NATIVE" "$LAST_RES/native.darshan"; "$B/darshan-parser" --show-incomplete "$NATIVE" | grep -E "^(POSIX|STDIO|MPIIO)" | sort > "$LAST_RES/n.txt" || true; }
    "$PY" - "$LAST_RES/r.txt" "$LAST_RES/n.txt" <<'PY' | tee "$LAST_RES/compare.txt"
import sys, os
from collections import Counter
def mods_ops(path):
    mods=set(); v=Counter()
    if os.path.exists(path):
        for ln in open(path):
            f=ln.split()
            if len(f)<5: continue
            mods.add(f[0]); cn=f[3]
            for op in ("OPENS","READS","WRITES","CLOSES"):
                if cn.endswith("_%s"%op):
                    try: v[op]+=int(f[4])
                    except ValueError: pass
    return mods, v
rm,ro=mods_ops(sys.argv[1]); nm,no=mods_ops(sys.argv[2])
print("reconstructed modules:", sorted(rm), " op-totals:", dict(ro))
print("native        modules:", sorted(nm), " op-totals:", dict(no))
if not (os.path.exists(sys.argv[2]) and nm):
    print("VERDICT: PARTIAL (no native log to compare)"); sys.exit(0)
ok = rm==nm and all(ro.get(k)==no.get(k) for k in ("OPENS","READS","WRITES","CLOSES"))
print("VERDICT:", "PASS" if ok else "MISMATCH")
PY
    # exe / mounts / heatmap presence check on the reconstructed log
    echo "-- exe/mounts --"; "$B/darshan-parser" "$PARTIAL" 2>/dev/null | grep -iE '^# exe|^# mount entry' | head
    ( cd "$LAST_RES" && "$PY" -c "import darshan; r=darshan.DarshanReport('partial.darshan',read_all=True); print('heatmaps:', list(r.heatmaps.keys()), {m:sum(int(a.sum()) for a in h.__dict__['_data']['write'].values()) for m,h in r.heatmaps.items()})" 2>&1 | tail -1 )
    ( cd "$LAST_RES" && "$PY" -m darshan summary partial.darshan >/dev/null 2>&1 && echo "HTML: $(ls "$LAST_RES"/*.html 2>/dev/null | head -1)" ) || true
else
    echo "reconstruct produced no log (no events?)"
fi

# --- 10. report ---
say "10. report"
"$PY" - "$CSV" <<'PY' | tee "$RESBASE/report.txt"
import sys, csv, statistics as st
rows=list(csv.DictReader(open(sys.argv[1])))
def wall(cond): return [float(r["wall_s"]) for r in rows if r["condition"]==cond]
b, s = wall("baseline"), wall("streaming")
print("OVERHEAD STUDY")
print(f"  baseline  wall_s: {b}  mean={st.mean(b):.3f}" if b else "  baseline: none")
print(f"  streaming wall_s: {s}  mean={st.mean(s):.3f}" if s else "  streaming: none")
if b and s:
    ov = (st.mean(s)-st.mean(b))/st.mean(b)*100
    print(f"  streaming overhead vs baseline: {ov:+.1f}%  (mean {st.mean(s)-st.mean(b):+.3f}s)")
push=[(int(r["sends"]),float(r["mean_push_us"]),float(r["median_push_us"])) for r in rows if r["condition"]=="streaming" and int(r["sends"])>0]
if push:
    tot=sum(p[0] for p in push)
    mean=sum(p[0]*p[1] for p in push)/tot
    print(f"  sustained push cost: {tot} sends across reps, weighted mean={mean:.3f}us, "
          f"per-rep median range={min(p[2] for p in push):.3f}-{max(p[2] for p in push):.3f}us")
print(f"  full CSV: {sys.argv[1]}")
PY

say "STUDY DONE"
echo "results: $RESBASE"
