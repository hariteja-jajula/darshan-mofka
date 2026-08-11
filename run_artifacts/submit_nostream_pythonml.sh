#!/bin/bash
# submit_nostream_pythonml.sh -- stripped-down twin of submit_cxi.sh (python-ml).
# NO Mofka/FlowCept streaming, NO broker, NO consumer, NO reconstruct/compare.
# Submits ONE PBS job that runs, for REPS reps, two arms:
#   darshan    LD_PRELOAD=libdarshan.so + DARSHAN_ENABLE_NONMPI=1 -> native .darshan, no streaming
#   nodarshan  no LD_PRELOAD                                       -> raw workload, no instrumentation
# Same python-ml config as submit_cxi.sh (EVENTS=100 -> ML_EPOCHS=100, CHECKPOINTS=2,
# dataset = train.py defaults 6x512x16). Run with bash, NOT qsub:
#   PBS_ACCOUNT=radix-io bash run_artifacts/submit_nostream_pythonml.sh
set -euo pipefail

# ===================== KNOBS (edit these) =====================
NODES=2               # mirror submit_cxi.sh allocation (2nd node idle -- no broker needed)
REPS=2               # reps per arm (matches submit_cxi.sh)
EVENTS=1000          # -> ML_EPOCHS (matches submit_cxi.sh). ~9min raw run at the big dataset below
CHECKPOINTS=2        # -> ML_CHECKPOINTS
QUEUE=debug          # debug (<=2 nodes, 1h)
WALLTIME=01:00:00
NCPUS=32             # Polaris compute node = 32 physical cores
STUDY=NOSTREAM_pythonml   # results/<STUDY>/<arm>/RUN<n>
# dataset size: big, matches submit_cxi.sh + PAPER_pythonml calibration (400ep=211s baseline)
export ML_FILES=64 ML_ROWS=4096 ML_COLS=64
# non-invasive per-core CPU sampling (mpstat -P ALL every N s -> RES/mpstat.txt):
DM_MPSTAT=1
DM_MPSTAT_INT=5
account=radix-io
# ==============================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
account="${PBS_ACCOUNT:-$account}"
[ -n "$account" ] || { echo "set PBS_ACCOUNT=<project>"; exit 1; }

# Polaris needs -l filesystems (home + eagle are distinct Lustre mounts).
source "$ROOT/env/_profile.sh" >/dev/null 2>&1 || true
PBS_EXTRA=()
[[ "${ENV_PROFILE:-}" == polaris ]] && PBS_EXTRA+=(-l "filesystems=${PBS_FILESYSTEMS:-home:eagle}")

# Forward workload knobs (all space-free) into the job environment via qsub -v.
FWD="ROOT=$ROOT,RESULTS_TAG=$STUDY,REPS=$REPS,ML_EPOCHS=$EVENTS,ML_CHECKPOINTS=$CHECKPOINTS"
FWD="$FWD,DM_MPSTAT=$DM_MPSTAT,DM_MPSTAT_INT=$DM_MPSTAT_INT"
[ -n "${ML_FILES:-}" ] && FWD="$FWD,ML_FILES=$ML_FILES"
[ -n "${ML_ROWS:-}" ]  && FWD="$FWD,ML_ROWS=$ML_ROWS"
[ -n "${ML_COLS:-}" ]  && FWD="$FWD,ML_COLS=$ML_COLS"

echo "submit: select=${NODES}:ncpus=${NCPUS} q=$QUEUE wall=$WALLTIME | python-ml NO-STREAM | arms=darshan+nodarshan reps=$REPS ML_EPOCHS=$EVENTS -> results/$STUDY/"
qsub -A "$account" -q "$QUEUE" \
     -l select="${NODES}:ncpus=${NCPUS}:mpiprocs=${NCPUS}" -l walltime="$WALLTIME" \
     "${PBS_EXTRA[@]}" -N dm_nostream_pyml -j oe -o "$ROOT/results/" -v "$FWD" <<'PBS'
#!/bin/bash
set -uo pipefail
cd "$ROOT"
ARMS="darshan nodarshan"          # both no-streaming; edit to run just one arm

module unload darshan 2>/dev/null || true
# libdarshan.so links diaspora + spack-view libs, so its deps must be on LD_LIBRARY_PATH
# even for the native-only arm (the connector is compiled in but never armed here).
source env/workload.sh >/dev/null 2>&1
export WL_TYPE=python-ml
DLIB="$(darshan_lib)"
PY="$ROOT/install/_venv/bin/python3"; [ -x "$PY" ] || PY="$(command -v python3)"
echo "nostream: DLIB=$DLIB PY=$PY ML_EPOCHS=$ML_EPOCHS ML_CHECKPOINTS=$ML_CHECKPOINTS arms='$ARMS' reps=$REPS host=$(hostname -s)"

for arm in $ARMS; do
  for rep in $(seq 1 "$REPS"); do
    RES="$ROOT/results/$RESULTS_TAG/$arm/RUN$rep"; mkdir -p "$RES"
    scratch="/tmp/dm_python-ml_${arm}_${rep}_$$"; mkdir -p "$scratch"
    echo "########## $arm rep $rep/$REPS -> $RES ##########"
    {
      echo "study=$RESULTS_TAG arm=$arm rep=$rep host=$(hostname -s) $(date -u +%FT%TZ)"
      echo "workload=python-ml streaming=OFF broker=NONE ML_EPOCHS=$ML_EPOCHS ML_CHECKPOINTS=$ML_CHECKPOINTS"
      echo "ML_FILES=${ML_FILES:-6(default)} ML_ROWS=${ML_ROWS:-512(default)} ML_COLS=${ML_COLS:-16(default)}"
      [ "$arm" = darshan ] && echo "darshan=ON LD_PRELOAD=$DLIB DARSHAN_ENABLE_NONMPI=1 (no Mofka)" \
                           || echo "darshan=OFF (raw workload)"
    } > "$RES/config.txt"

    # Non-invasive per-core CPU sampler: mpstat -P ALL in background for the workload window.
    mpid=""
    if [ "${DM_MPSTAT:-0}" = 1 ] && command -v mpstat >/dev/null 2>&1; then
      mpstat -P ALL "${DM_MPSTAT_INT:-5}" > "$RES/mpstat.txt" 2>/dev/null &
      mpid=$!
    fi
    echo "WORK_SH_START_NS $(date +%s%N)" > "$RES/workload.out"
    if [ "$arm" = darshan ]; then
      env DARSHAN_ENABLE_NONMPI=1 DARSHAN_LOGPATH="$RES" LD_PRELOAD="$DLIB" \
          ML_EPOCHS="$ML_EPOCHS" ML_CHECKPOINTS="$ML_CHECKPOINTS" \
          ${ML_FILES:+ML_FILES=$ML_FILES} ${ML_ROWS:+ML_ROWS=$ML_ROWS} ${ML_COLS:+ML_COLS=$ML_COLS} \
          "$PY" workloads/python-ml/train.py "$scratch" \
          >> "$RES/workload.out" 2> "$RES/workload.err" || echo "arm=$arm rep=$rep FAILED rc=$?"
    else
      env ML_EPOCHS="$ML_EPOCHS" ML_CHECKPOINTS="$ML_CHECKPOINTS" \
          ${ML_FILES:+ML_FILES=$ML_FILES} ${ML_ROWS:+ML_ROWS=$ML_ROWS} ${ML_COLS:+ML_COLS=$ML_COLS} \
          "$PY" workloads/python-ml/train.py "$scratch" \
          >> "$RES/workload.out" 2> "$RES/workload.err" || echo "arm=$arm rep=$rep FAILED rc=$?"
    fi
    echo "WORK_SH_END_NS $(date +%s%N)" >> "$RES/workload.out"
    [ -n "$mpid" ] && kill "$mpid" 2>/dev/null || true
    rm -rf "$scratch" 2>/dev/null || true

    if [ "$arm" = darshan ]; then
      nlog="$(ls "$RES"/*.darshan 2>/dev/null | head -1 || true)"
      echo "  native log: ${nlog:-<NONE written!>}"
    fi
    tail -1 "$RES/workload.out"
  done
done
echo "DONE -> results/$RESULTS_TAG/{darshan,nodarshan}/RUN*"
PBS
