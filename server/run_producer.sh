#!/bin/bash
# run_producer.sh -- MANUAL step 3: run a workload under the Darshan->Mofka connector
# (LD_PRELOAD libdarshan). Each I/O op is streamed to the broker's darshan topic.
# The server (server/start_server.sh) and consumer (Client/capture_flowcept.sh) must be
# running first.
#
#   bash server/run_producer.sh              # default: C io_bench (short)
#   bash server/run_producer.sh io_bench_py  # Python io_bench
#   WL=io_bench COMPUTE=2 IO_ITERS=8 bash server/run_producer.sh
#
# Knobs: WL (io_bench|io_bench_py), TOPIC (darshan), IO_ITERS, IO_SLEEP_MS, COMPUTE, MATRIX_SIZE.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
source env/workload.sh >/dev/null 2>&1 || true

WL="${1:-${WL:-io_bench}}"
TOPIC="${TOPIC:-darshan}"
GROUP="$ROOT/server/mofka.json"
DLIB="$ROOT/darshan/install/lib/libdarshan.so"
SCRATCH="/tmp/dm_manual_$$"; mkdir -p "$SCRATCH"

[ -f "$GROUP" ] || { echo "no $GROUP -- start the broker first: bash server/start_server.sh"; exit 1; }
[ -e "$DLIB" ]  || { echo "libdarshan.so missing at $DLIB (build it: ./build.sh)"; exit 1; }

# build the C workload if needed
if [ "$WL" = io_bench ] && [ ! -x "workloads/c/io_bench" ]; then
    echo "compiling io_bench..."; cc -O2 workloads/c/io_bench.c -o workloads/c/io_bench || exit 1
fi
case "$WL" in
    io_bench)    CMD=(./workloads/c/io_bench "$SCRATCH") ;;
    io_bench_py) CMD=("${PY:-python3}" workloads/python-ml/io_bench.py "$SCRATCH") ;;
    python-ml)   CMD=("${PY:-python3}" workloads/python-ml/train.py "$SCRATCH") ;;
    *) echo "unknown WL=$WL (use io_bench | io_bench_py | python-ml)"; exit 1 ;;
esac

# small defaults so the manual demo finishes quickly (override via env)
export IO_SIZE_MB="${IO_SIZE_MB:-4}" IO_ITERS="${IO_ITERS:-4}" IO_SLEEP_MS="${IO_SLEEP_MS:-50}"
export COMPUTE="${COMPUTE:-0}" MATRIX_SIZE="${MATRIX_SIZE:-128}"

echo "=== producer: $WL -> topic '$TOPIC' (streaming ON) ==="
echo "  group=$GROUP  lib=$DLIB  iters=$IO_ITERS"
env \
  DARSHAN_ENABLE_NONMPI=1 \
  DARSHAN_MOFKA_ENABLE=1 \
  DARSHAN_MOFKA_GROUP_FILE="$GROUP" \
  DARSHAN_MOFKA_TOPIC="$TOPIC" \
  DARSHAN_MOFKA_TIMING=1 \
  DARSHAN_MOFKA_VERBOSE=1 \
  MOFKA_CLIENT_MODE=1 \
  DIASPORA_C_SENDER_THREADS=1 \
  DARSHAN_LOGPATH="$SCRATCH" \
  LD_PRELOAD="$DLIB" \
  "${CMD[@]}"
rc=$?
echo "=== producer done (rc=$rc). streamed events are now in the broker/consumer. ==="
rm -rf "$SCRATCH" 2>/dev/null || true
