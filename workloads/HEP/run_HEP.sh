
#!/bin/bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

WLNODES=1
SRVNODES=1

WORKLOAD=hep-salt
PROTO=ofi+cxi
TASKS=1

REPS="${REPS:-1}"

PARTITIONS=4
CONSUMERS=1

# Reuse existing custom Darshan/Mofka build.
SKIP_BUILD=1

STUDY="${STUDY:-HEP_SALT_smoke}"

source "$ROOT/overhead_study/_submit_lib.sh"
























# #!/bin/bash
# #PBS -A radix-io
# #PBS -q debug
# #PBS -l select=2:ncpus=32:mpiprocs=32
# #PBS -l walltime=00:15:00
# #PBS -l filesystems=home:eagle
# #PBS -N darshan_hep
# #PBS -l singularity_fakeroot=true
# #PBS -j oe

# set -uo pipefail

# ROOT=/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight
# HEP="$ROOT/workloads/HEP"

# SIF="$HEP/salt-dev.sif"
# DLIB="$ROOT/darshan/install/lib/libdarshan.so"

# # --------------------------------------------------------------------------
# # If launched from login node, submit this same script.
# # --------------------------------------------------------------------------

# if [ -z "${PBS_JOBID:-}" ]; then
#     exec qsub "$0"
# fi

# cd "$ROOT" || exit 1

# echo "============================================================"
# echo " Darshan-Mofka HEP/SALT smoke test"
# echo " job:   $PBS_JOBID"
# echo " root:  $ROOT"
# echo " image: $SIF"
# echo "============================================================"

# # --------------------------------------------------------------------------
# # Existing project environment.
# # --------------------------------------------------------------------------

# source "$ROOT/env/server.sh" || exit 1
# source "$ROOT/env/workload.sh" || exit 1
# source "$ROOT/lib/run.sh" || exit 1

# module unload darshan 2>/dev/null || true

# # --------------------------------------------------------------------------
# # Tell the existing config helpers exactly what this run is.
# # --------------------------------------------------------------------------

# export WORKLOAD=hep-salt

# export NODES=2
# export TASKS=1
# export PLACEMENT=separate

# export MOFKA_PROTOCOL=ofi+cxi
# export MOFKA_TOPIC=darshan

# export PARTITIONS="${PARTITIONS:-4}"
# export CONSUMERS="${CONSUMERS:-1}"

# export DARSHAN_MOFKA_ENABLE=1
# export DARSHAN_MOFKA_TIMING="${DARSHAN_MOFKA_TIMING:-1}"

# # Preserve normal configured values unless explicitly overridden.
# export DARSHAN_MOFKA_BATCH="${DARSHAN_MOFKA_BATCH:-0}"
# export DARSHAN_MOFKA_MAX_BATCHES="${DARSHAN_MOFKA_MAX_BATCHES:-512}"
# export DARSHAN_MOFKA_FLUSH_MS="${DARSHAN_MOFKA_FLUSH_MS:-30000}"

# export DIASPORA_C_SENDER_THREADS="${DIASPORA_C_SENDER_THREADS:-1}"

# load_run_config

# # --------------------------------------------------------------------------
# # Validate files.
# # --------------------------------------------------------------------------

# [ -f "$SIF" ] || {
#     echo "ERROR: missing $SIF"
#     exit 1
# }

# [ -f "$DLIB" ] || {
#     echo "ERROR: missing custom Darshan: $DLIB"
#     exit 1
# }

# echo
# echo "custom Darshan:"
# ls -l "$DLIB"

# # --------------------------------------------------------------------------
# # Results.
# # --------------------------------------------------------------------------

# JOBID="${PBS_JOBID%%.*}"

# RES="$ROOT/results/HEP_SALT/RUN_${JOBID}"
# COORD="$RES/coord"
# SEC="$RES/sections"

# mkdir -p \
#     "$RES" \
#     "$COORD" \
#     "$SEC" \
#     "$RES/fc" \
#     "$HEP/logs" \
#     "$HEP/darshan_logs"

# echo "results: $RES"

# # --------------------------------------------------------------------------
# # Resolve Polaris nodes.
# # --------------------------------------------------------------------------

# mapfile -t NODELIST < <(
#     sort -u "$PBS_NODEFILE"
# )

# if [ "${#NODELIST[@]}" -lt 2 ]; then
#     echo "ERROR: need 2 nodes"
#     exit 1
# fi

# SRV_NODE="${NODELIST[0]}"
# WL_NODE="${NODELIST[1]}"

# echo
# echo "broker/consumer node: $SRV_NODE"
# echo "SALT workload node:    $WL_NODE"

# # --------------------------------------------------------------------------
# # Other infrastructure used by FlowCept.
# # --------------------------------------------------------------------------

# MONGOD="${MONGOD:-$(command -v mongod || true)}"

# [ -x "$MONGOD" ] || {
#     echo "ERROR: mongod not found"
#     exit 1
# }

# export MONGOD

# # --------------------------------------------------------------------------
# # Bedrock config.
# # --------------------------------------------------------------------------

# render_bedrock_config \
#     "$ROOT/server/bedrock-config.json" \
#     "$COORD/bedrock-config.json"

# # --------------------------------------------------------------------------
# # Build exact producer environment using existing harness logic.
# #
# # GROUP does not exist yet, but everybody will use the eventual shared file.
# # --------------------------------------------------------------------------

# GROUP="$COORD/mofka.json"

# connector_env "$GROUP"
# darshan_env

# # Turn the arrays into exported variables for the SALT section.
# for kv in "${CONNECTOR_ENV[@]}"; do
#     export "$kv"
# done

# for kv in "${DARSHAN_ENV[@]}"; do
#     export "$kv"
# done

# # --------------------------------------------------------------------------
# # Existing Polaris CXI fixes.
# # --------------------------------------------------------------------------

# STRIP="$(pmi_strip)"
# COLLAPSE="$(cxi_collapse)"

# # ==========================================================================
# # BROKER SECTION
# # ==========================================================================

# cat > "$SEC/broker.sh" <<EOF
# #!/bin/bash

# ROOT='$ROOT'
# COORD='$COORD'
# RES='$RES'
# PROFILE='$ENV_PROFILE'
# SRV_PROTOCOL='ofi+cxi'

# $STRIP
# $COLLAPSE

# cd "\$COORD"

# source "\$ROOT/env/server.sh" --"\$PROFILE" >/dev/null 2>&1

# rm -f "\$COORD/mofka.json"

# echo "BROKER host=\$(hostname -s) VNIS=[\${SLINGSHOT_VNIS:-}]" >&2

# exec bedrock \
#     "\$SRV_PROTOCOL" \
#     -c "\$COORD/bedrock-config.json" \
#     -v info \
#     > "\$RES/broker.log" 2>&1 </dev/null
# EOF

# # ==========================================================================
# # FLOWCEPT SECTION
# # ==========================================================================

# cat > "$SEC/consumer.sh" <<EOF
# #!/bin/bash

# ROOT='$ROOT'
# COORD='$COORD'
# RES='$RES'
# PROFILE='$ENV_PROFILE'

# $STRIP
# $COLLAPSE

# cd "\$ROOT"

# source "\$ROOT/env/server.sh" --"\$PROFILE" >/dev/null 2>&1
# source "\$ROOT/lib/run.sh"

# export WORKLOAD=hep-salt
# export NODES=2
# export TASKS=1
# export PLACEMENT=separate

# export MOFKA_PROTOCOL=ofi+cxi
# export MOFKA_TOPIC=darshan

# export PARTITIONS='$PARTITIONS'
# export CONSUMERS=1

# load_run_config

# echo "CONSUMER host=\$(hostname -s) VNIS=[\${SLINGSHOT_VNIS:-}]" >&2

# # Wait for broker group file.
# for _ in \$(seq 1 180); do
#     [ -s "\$COORD/mofka.json" ] && break
#     sleep 1
# done

# if [ ! -s "\$COORD/mofka.json" ]; then
#     echo "consumer: mofka.json never appeared" >&2
#     touch "\$COORD/CONS_FAIL.0"
#     exit 1
# fi

# # Create the same topic + partitions as the normal harness.
# broker_topic_partitions \
#     "\$COORD/mofka.json" \
#     1

# touch "\$COORD/TOPIC_READY"

# sleep 3

# CDIR="\$RES/fc/c0"
# mkdir -p "\$CDIR"

# FC_ROLE=lead \
# RUN_DIR="\$CDIR" \
# FLAGDIR="\$COORD" \
# MONGO_DB="\$SRV_MONGO_DB" \
# MONGO_PORT="\$SRV_MONGO_PORT" \
# MONGOD="\$MONGOD" \
# MONGO_CACHE_GB="\$SRV_MONGO_CACHE_GB" \
# MONGO_DBPATH="\$SRV_MONGO_DBPATH" \
# TOPIC="\$SRV_TOPIC" \
# MOFKA_GROUP="\$COORD/mofka.json" \
# MQ_BUFFER_SIZE="\$CONS_MQ_BUF" \
# MQ_FLUSH_SECS="\$CONS_MQ_FLUSH" \
# DB_BUFFER_SIZE="\$CONS_DB_BUF" \
# DB_FLUSH_SECS="\$CONS_DB_FLUSH" \
# SHUTDOWN_FLAG="\$COORD/SHUTDOWN" \
# EXPORT_ON_STOP=1 \
# EXPORT_OUT="\$RES/events.jsonl" \
# ALL_DONE_FLAG="\$COORD/ALL_DONE" \
# bash "\$ROOT/Client/capture_flowcept.sh" \
#     > "\$CDIR/flowcept.out" 2>&1

# rc=\$?

# [ "\$rc" -ne 0 ] && touch "\$COORD/CONS_FAIL.0"

# exit "\$rc"
# EOF

# # ==========================================================================
# # SALT SECTION
# # ==========================================================================

# cat > "$SEC/workload.sh" <<'EOF'
# #!/bin/bash

# set -uo pipefail

# ROOT=/eagle/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight
# HEP="$ROOT/workloads/HEP"

# SIF="$HEP/salt-dev.sif"
# DLIB="$ROOT/darshan/install/lib/libdarshan.so"

# COORD="__COORD__"
# RES="__RES__"
# PROFILE="__PROFILE__"

# __STRIP__
# __COLLAPSE__

# cd "$ROOT"

# source "$ROOT/env/workload.sh" --"$PROFILE" >/dev/null 2>&1
# source "$ROOT/lib/run.sh"

# # Polaris Apptainer environment
# ml use /soft/modulefiles
# ml spack-pe-base
# ml apptainer

# if ! command -v apptainer >/dev/null 2>&1; then
#     echo "ERROR: apptainer not found after module load" >> "$RES/workload.err"
#     touch "$COORD/WL_FAIL.0"
#     exit 1
# fi

# echo "apptainer=$(command -v apptainer)" >> "$RES/workload.out"
# apptainer version >> "$RES/workload.out" 2>&1

# export APPTAINER_TMPDIR="/local/scratch/apptainer-tmpdir-${USER}"
# export APPTAINER_CACHEDIR="/local/scratch/apptainer-cache-${USER}"

# mkdir -p \
#     "$APPTAINER_TMPDIR" \
#     "$APPTAINER_CACHEDIR"

# # Same connector configuration as the existing harness.
# export WORKLOAD=hep-salt

# export NODES=2
# export TASKS=1
# export PLACEMENT=separate

# export MOFKA_PROTOCOL=ofi+cxi
# export MOFKA_TOPIC=darshan

# export PARTITIONS=4
# export CONSUMERS=1

# export DARSHAN_MOFKA_ENABLE=1
# export DARSHAN_MOFKA_TIMING="${DARSHAN_MOFKA_TIMING:-1}"
# export DARSHAN_MOFKA_BATCH="${DARSHAN_MOFKA_BATCH:-0}"
# export DARSHAN_MOFKA_MAX_BATCHES="${DARSHAN_MOFKA_MAX_BATCHES:-512}"
# export DARSHAN_MOFKA_FLUSH_MS="${DARSHAN_MOFKA_FLUSH_MS:-30000}"
# export DIASPORA_C_SENDER_THREADS="${DIASPORA_C_SENDER_THREADS:-1}"

# load_run_config

# connector_env "$COORD/mofka.json"
# darshan_env

# for kv in "${CONNECTOR_ENV[@]}"; do
#     export "$kv"
# done

# for kv in "${DARSHAN_ENV[@]}"; do
#     export "$kv"
# done

# echo "WORKLOAD host=$(hostname -s) VNIS=[${SLINGSHOT_VNIS:-}]" \
#     > "$RES/workload.out"

# # Wait until FlowCept has created the topic and is ready.
# for _ in $(seq 1 180); do
#     [ -f "$COORD/CONSUMER_READY" ] && break
#     sleep 1
# done

# if [ ! -f "$COORD/CONSUMER_READY" ]; then
#     echo "ERROR: CONSUMER_READY never appeared" >> "$RES/workload.out"
#     touch "$COORD/WL_FAIL.0"
#     exit 1
# fi

# echo "============================================================" \
#     >> "$RES/workload.out"

# echo "custom Darshan=$DLIB" \
#     >> "$RES/workload.out"

# echo "group=$DARSHAN_MOFKA_GROUP_FILE" \
#     >> "$RES/workload.out"

# echo "topic=$DARSHAN_MOFKA_TOPIC" \
#     >> "$RES/workload.out"

# # --------------------------------------------------------------------------
# # Host Mofka/Diaspora libraries must remain visible inside Apptainer.
# # --------------------------------------------------------------------------

# STACK_LD="$ROOT/darshan/install/lib:$ROOT/diaspora-stream-api/install/lib:${LD_LIBRARY_PATH:-}"

# BINDS=(
#     -B "$ROOT:$ROOT"
#     -B "$HEP/dummy_data:/workspace/dummy_data"
#     -B "$HEP/darshan_logs:/workspace/darshan_logs"
#     -B "$HEP/logs:/workspace/logs"
# )

# [ -d /opt/cray ] && BINDS+=(
#     -B /opt/cray:/opt/cray
# )

# # --------------------------------------------------------------------------
# # Verify torch first.
# # --------------------------------------------------------------------------

# echo "=== GPU CHECK ===" >> "$RES/workload.out"
# ml use /soft/modulefiles
# ml spack-pe-base
# ml apptainer

# env -u LD_PRELOAD \
#     APPTAINERENV_PREPEND_LD_LIBRARY_PATH="$STACK_LD" \
#     apptainer exec \
#         --nv \
#         --fakeroot \
#         "${BINDS[@]}" \
#         "$SIF" \
#         env PYTHONNOUSERSITE=1 \
#         python - <<'PY' \
#         >> "$RES/workload.out" \
#         2>> "$RES/workload.err"

# import torch

# print("torch version:", torch.__version__)
# print("torch CUDA build:", torch.version.cuda)
# print("torch path:", torch.__file__)
# print("cuda available:", torch.cuda.is_available())

# if torch.cuda.is_available():
#     print("GPU:", torch.cuda.get_device_name(0))
# PY

# # --------------------------------------------------------------------------
# # Verify custom Darshan dependencies inside container.
# # --------------------------------------------------------------------------

# echo "=== DARSHAN LDD ===" >> "$RES/workload.out"

# env -u LD_PRELOAD \
#     APPTAINERENV_PREPEND_LD_LIBRARY_PATH="$STACK_LD" \
#     apptainer exec \
#         --nv \
#         --fakeroot \
#         "${BINDS[@]}" \
#         "$SIF" \
#         ldd "$DLIB" \
#         >> "$RES/workload.out" \
#         2>> "$RES/workload.err"

# if env -u LD_PRELOAD \
#     APPTAINERENV_PREPEND_LD_LIBRARY_PATH="$STACK_LD" \
#     apptainer exec \
#         --nv \
#         --fakeroot \
#         "${BINDS[@]}" \
#         "$SIF" \
#         ldd "$DLIB" | grep -q 'not found'
# then
#     echo "ERROR: unresolved custom Darshan dependency" \
#         >> "$RES/workload.err"

#     touch "$COORD/WL_FAIL.0"
#     exit 1
# fi

# # --------------------------------------------------------------------------
# # SALT
# #
# # IMPORTANT:
# # LD_PRELOAD is passed to the CONTAINED process, not to apptainer itself.
# # --------------------------------------------------------------------------

# echo "WORK_SH_START_NS $(date +%s%N)" \
#     >> "$RES/workload.out"

# cd "$HEP"

# env -u LD_PRELOAD \
#     APPTAINERENV_PREPEND_LD_LIBRARY_PATH="$STACK_LD" \
#     apptainer exec \
#         --nv \
#         --fakeroot \
#         "${BINDS[@]}" \
#         --env "PYTHONNOUSERSITE=1" \
#         --env "LD_PRELOAD=$DLIB" \
#         --env "DARSHAN_LD_PRELOAD=$DLIB" \
#         "$SIF" \
#         salt fit --force \
#             --config /workspace/salt/salt/configs/GN2/GN2.yaml \
#             --trainer.devices=1 \
#             --data.batch_size=64 \
#             --data.num_workers=4 \
#             --data.persistent_workers=true \
#             --data.multiprocessing_context=spawn \
#             --data.train_file=/workspace/dummy_data/train.h5 \
#             --data.val_file=/workspace/dummy_data/val.h5 \
#             --data.norm_dict=/workspace/dummy_data/norm_dict.yaml \
#             --data.class_dict=/workspace/dummy_data/class_dict.yaml \
#             --data.num_train=1000 \
#             --data.num_val=200 \
#             --trainer.max_epochs=2 \
#             --name=GN2_streaming \
#             >> "$RES/workload.out" \
#             2>> "$RES/workload.err"

# rc=$?

# echo "WORK_SH_END_NS $(date +%s%N)" \
#     >> "$RES/workload.out"

# touch "$COORD/WL_DONE.0"

# if [ "$rc" -ne 0 ]; then
#     touch "$COORD/WL_FAIL.0"
# fi

# exit "$rc"
# EOF

# # Fill generated-script placeholders.
# sed -i \
#     -e "s|__COORD__|$COORD|g" \
#     -e "s|__RES__|$RES|g" \
#     -e "s|__PROFILE__|$ENV_PROFILE|g" \
#     "$SEC/workload.sh"

# # STRIP/COLLAPSE are shell fragments, so insert them separately.
# python3 - "$SEC/workload.sh" "$STRIP" "$COLLAPSE" <<'PY'
# import sys

# path, strip, collapse = sys.argv[1:4]

# s = open(path).read()
# s = s.replace("__STRIP__", strip)
# s = s.replace("__COLLAPSE__", collapse)

# open(path, "w").write(s)
# PY

# chmod +x \
#     "$SEC/broker.sh" \
#     "$SEC/consumer.sh" \
#     "$SEC/workload.sh"

# # ==========================================================================
# # ONE MPMD LAUNCH
# # ==========================================================================

# echo
# echo "=== starting one MPMD CXI launch ==="
# echo "broker:   $SRV_NODE"
# echo "consumer: $SRV_NODE"
# echo "workload: $WL_NODE"

# mpi_launch_mpmd \
#     "$SRV_NODE 1 $SEC/broker.sh" \
#     "$SRV_NODE 1 $SEC/consumer.sh" \
#     "$WL_NODE 1 $SEC/workload.sh"

# "${MPI_MPMD[@]}" \
#     > "$RES/mpmd.log" 2>&1 &

# MPMD_PID=$!

# # ==========================================================================
# # Drive shutdown.
# # ==========================================================================

# deadline=$(( $(date +%s) + 900 ))
# shutdown_sent=0
# verdict=""

# while :; do

#     if [ "$shutdown_sent" = 0 ] &&
#        [ -f "$COORD/WL_DONE.0" ]
#     then
#         echo "SALT finished -> stopping FlowCept"
#         touch "$COORD/SHUTDOWN"
#         shutdown_sent=1
#     fi

#     if [ -f "$COORD/ALL_DONE" ]; then
#         verdict="all_done"
#         break
#     fi

#     if find "$COORD" \
#         -maxdepth 1 \
#         -name '*_FAIL.*' \
#         2>/dev/null | grep -q .
#     then
#         verdict="failure"
#         break
#     fi

#     if ! kill -0 "$MPMD_PID" 2>/dev/null; then
#         verdict="mpiexec_exit"
#         break
#     fi

#     if [ "$(date +%s)" -ge "$deadline" ]; then
#         verdict="timeout"
#         break
#     fi

#     sleep 3
# done

# # Broker deliberately remains alive, so terminate whole MPMD launch.
# kill "$MPMD_PID" 2>/dev/null || true
# pkill -f 'bedrock ' 2>/dev/null || true

# wait "$MPMD_PID" 2>/dev/null || true

# echo
# echo "============================================================"
# echo " HEP result"
# echo "============================================================"
# echo "verdict=$verdict"
# echo "results=$RES"

# EVENTS=0

# if [ -f "$RES/events.jsonl" ]; then
#     EVENTS="$(wc -l < "$RES/events.jsonl")"
# fi

# echo "streamed_events=$EVENTS"

# grep -E \
#     'INGEST:|tasks total=' \
#     "$RES/fc/c0/flowcept.out" \
#     2>/dev/null || true

# echo
# echo "Darshan timing:"
# grep 'darshan-mofka' \
#     "$RES/workload.err" \
#     2>/dev/null || true

# echo
# echo "SALT/GPU:"
# grep -E \
#     'torch version:|torch CUDA build:|cuda available:|GPU:|Epoch|Trainer.fit' \
#     "$RES/workload.out" \
#     2>/dev/null | tail -30 || true

# if [ "$verdict" = all_done ] &&
#    [ "$EVENTS" -gt 0 ]
# then
#     echo
#     echo "SUCCESS: SALT -> custom Darshan -> Mofka -> FlowCept"
#     exit 0
# fi

# echo
# echo "FAILED: inspect:"
# echo "  $RES/workload.err"
# echo "  $RES/mpmd.log"
# echo "  $RES/broker.log"
# echo "  $RES/fc/c0/flowcept.out"

# exit 1