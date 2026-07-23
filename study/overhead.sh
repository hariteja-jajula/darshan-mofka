#!/bin/bash
# study/overhead.sh -- measure the Darshan->Mofka connector's overhead.
#
# For each workload (C smoke, python-ml) it times three configurations, REPS times
# each, and reports mean/stddev walltime plus the connector's own init / finalize /
# average-push timings (from DARSHAN_MOFKA_TIMING):
#
#   noinstr   no Darshan at all            (pure workload baseline)
#   baseline  Darshan loaded, Mofka off    (Darshan-native cost)
#   mofka     Darshan + Mofka streaming    (adds the connector cost)
#
# The interesting number is mofka - baseline: what the streaming connector adds on
# top of plain Darshan. Writes results/overhead_<ts>/overhead.csv + summary.txt.
#
# Run on a compute node from the repo root (needs the broker):  bash study/overhead.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
REPS="${REPS:-3}"
# shellcheck disable=SC1091
source env/server.sh; source env/workload.sh
module unload darshan 2>/dev/null || true
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"

STAMP="$(date +%Y%m%d_%H%M%S)"; RES="$ROOT/results/overhead_$STAMP"; mkdir -p "$RES"
CSV="$RES/overhead.csv"
echo "workload,config,rep,walltime_s,sends,init_us,finalize_us,avg_push_us" > "$CSV"

[ -e "$(darshan_lib)" ] || ./build.sh
DLIB="$(darshan_lib)"
"$CC" -O2 workloads/c/mofka_forward_smoke.c -o workloads/c/mofka_forward_smoke

# broker only (producer-side overhead; the full consumer path is covered by job.sh)
bash server/stop_server.sh >/dev/null 2>&1 || true; sleep 1
bash server/start_server.sh
GROUP="$ROOT/server/mofka.json"
trap 'bash server/stop_server.sh >/dev/null 2>&1 || true' EXIT

# one timed run -> appends a CSV row. args: workload config rep
run_one() {
    local wl="$1" cfg="$2" rep="$3"
    local dir="$RES/${wl}_${cfg}_${rep}"; mkdir -p "$dir"
    local err="$dir/run.err"
    local -a pre=() cmd=()
    case "$wl" in
        c)         cmd=(./workloads/c/mofka_forward_smoke "$dir/data") ;;
        python-ml) cmd=("$PY" workloads/python-ml/train.py "$dir/data") ;;
    esac
    case "$cfg" in
        noinstr)  pre=() ;;
        baseline) pre=(env DARSHAN_ENABLE_NONMPI=1 DARSHAN_LOGPATH="$DARSHAN_LOGPATH" LD_PRELOAD="$DLIB") ;;
        mofka)    pre=(env DARSHAN_ENABLE_NONMPI=1 DARSHAN_LOGPATH="$DARSHAN_LOGPATH" LD_PRELOAD="$DLIB"
                       DARSHAN_MOFKA_ENABLE=1 DARSHAN_MOFKA_GROUP_FILE="$GROUP" DARSHAN_MOFKA_TOPIC=darshan
                       DARSHAN_MOFKA_BATCH=0 DARSHAN_MOFKA_MAX_BATCHES=64 DARSHAN_MOFKA_TIMING=1) ;;
    esac
    local t0 t1; t0=$(date +%s.%N)
    "${pre[@]}" "${cmd[@]}" > "$dir/run.out" 2> "$err" || true
    t1=$(date +%s.%N)
    local wall; wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f", b-a}')
    local sends init fin avgpush
    sends=$(grep -c 'darshan-mofka\[timing\] send' "$err" 2>/dev/null || echo 0)
    init=$(awk '/darshan-mofka\[timing\] initialize/{print $(NF-1)}' "$err" | tail -1); init="${init:-}"
    fin=$(awk '/darshan-mofka\[timing\] finalize/{print $(NF-1)}' "$err" | tail -1); fin="${fin:-}"
    avgpush=$(awk '/darshan-mofka\[timing\] send/{s+=$(NF-1); n++} END{if(n)printf "%.3f", s/n}' "$err")
    echo "$wl,$cfg,$rep,$wall,$sends,$init,$fin,$avgpush" >> "$CSV"
    echo "  $wl/$cfg rep$rep: wall=${wall}s sends=${sends} init=${init}us finalize=${fin}us avg_push=${avgpush}us"
}

for wl in c python-ml; do
    for cfg in noinstr baseline mofka; do
        for rep in $(seq 1 "$REPS"); do run_one "$wl" "$cfg" "$rep"; done
    done
done

# summary: mean/stddev walltime per (workload,config) + connector cost
"$PY" - "$CSV" "$RES/summary.txt" <<'PY'
import csv, sys, statistics as st
rows=list(csv.DictReader(open(sys.argv[1])))
def agg(wl,cfg,key):
    xs=[float(r[key]) for r in rows if r["workload"]==wl and r["config"]==cfg and r[key] not in ("","nan")]
    return xs
out=[]
out.append("Overhead summary (walltime seconds; connector timings in microseconds)\n")
for wl in ("c","python-ml"):
    out.append(f"\n== {wl} ==")
    base=None
    for cfg in ("noinstr","baseline","mofka"):
        w=agg(wl,cfg,"walltime_s")
        if not w: continue
        m=st.mean(w); sd=st.pstdev(w) if len(w)>1 else 0.0
        line=f"  {cfg:9s} walltime mean={m:.4f}s stddev={sd:.4f}s (n={len(w)})"
        if cfg=="baseline": base=m
        if cfg=="mofka" and base is not None:
            line+=f"   -> connector adds {m-base:+.4f}s ({100*(m-base)/base:+.1f}% vs baseline)"
        out.append(line)
    inits=agg(wl,"mofka","init_us"); fins=agg(wl,"mofka","finalize_us"); ap=agg(wl,"mofka","avg_push_us")
    if inits: out.append(f"  connector: init mean={st.mean(inits):.1f}us  finalize mean={st.mean(fins):.1f}us  avg_push mean={st.mean(ap):.3f}us")
txt="\n".join(out)+"\n"
open(sys.argv[2],"w").write(txt); print(txt)
PY
echo "=== overhead study done -> $RES ==="
