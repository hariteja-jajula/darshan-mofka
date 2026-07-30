#!/bin/bash
# start_server.sh -- self-contained Bedrock/Mofka broker launcher.
# Reuses env/server.sh for the environment; reads no *.config and
# does not source lib/run.sh. Stop with server/stop_server.sh.
#   bash server/start_server.sh --polaris
#   MOFKA_PROTOCOL=ofi+cxi MOFKA_PARTITIONS=2 bash server/start_server.sh --polaris
set -e

# ---- editable defaults (override from the shell) ---------------------------
MOFKA_PROTOCOL="${MOFKA_PROTOCOL:-auto}"                # auto -> profile default (never BEDROCK_PROTOCOL)
MOFKA_TOPIC="${MOFKA_TOPIC:-darshan}"
MOFKA_PARTITIONS="${MOFKA_PARTITIONS:-1}"
MOFKA_NRANKS="${MOFKA_NRANKS:-1}"
MOFKA_PARTITION_TYPE="${MOFKA_PARTITION_TYPE:-memory}"  # memory | default
MOFKA_PARTITION_PATH="${MOFKA_PARTITION_PATH:-/tmp/mofka_parts_$$}"
RPC_THREAD_COUNT="${RPC_THREAD_COUNT:-16}"
USE_PROGRESS_THREAD="${USE_PROGRESS_THREAD:-true}"
# ---------------------------------------------------------------------------

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOFKA_SERVER_DIR="${MOFKA_SERVER_DIR:-$HERE}"

# shellcheck disable=SC1091
source "$HERE/../env/server.sh" "$@"

# auto resolves to the profile default only (BEDROCK_PROTOCOL is deliberately not
# consulted: on Polaris it can carry a stray ofi+cxi with no VNI -> Margo aborts).
[ "$MOFKA_PROTOCOL" = auto ] && MOFKA_PROTOCOL="${MOFKA_PROTOCOL_DEFAULT:-tcp}"

[ "$MOFKA_PARTITION_TYPE" = default ] && [ -z "$MOFKA_PARTITION_PATH" ] && {
    echo "ERROR: MOFKA_PARTITION_TYPE=default needs MOFKA_PARTITION_PATH"; exit 2; }

TEMPLATE="$HERE/bedrock-config.json"
RUNTIME="$MOFKA_SERVER_DIR/bedrock-config.runtime.json"
[ -f "$TEMPLATE" ] || { echo "ERROR: missing template $TEMPLATE"; exit 1; }

mkdir -p "$MOFKA_SERVER_DIR"
cd "$MOFKA_SERVER_DIR"
[ -f bedrock.pid ] && kill "$(cat bedrock.pid)" 2>/dev/null || true
sleep 1
rm -f mofka.json bedrock.pid

# Render runtime config from the template; never overwrite the template itself.
"$PY" - "$TEMPLATE" "$RUNTIME" "$RPC_THREAD_COUNT" "$USE_PROGRESS_THREAD" <<'PY'
import json, os, sys
tmpl, out, rpc, prog = sys.argv[1:5]
if os.path.realpath(tmpl) == os.path.realpath(out):
    sys.exit("refusing to overwrite template: %s" % tmpl)
d = json.load(open(tmpl))
d.setdefault("margo", {})["rpc_thread_count"] = int(rpc)
d["margo"]["use_progress_thread"] = str(prog).lower() == "true"
json.dump(d, open(out, "w"), indent=4)
PY

echo "starting bedrock ($MOFKA_PROTOCOL) in $MOFKA_SERVER_DIR ..."
case "$MOFKA_PROTOCOL" in
    *cxi*)
        # --single-node-vni injects the VNI; collapse Polaris's two VNIs to one (margo mishandles multi-VNI).
        mpiexec --single-node-vni --ppn 1 -n "$MOFKA_NRANKS" -- \
            bash -c '
                export SLINGSHOT_VNIS=${SLINGSHOT_VNIS%%,*}
                export SLINGSHOT_SVC_IDS=${SLINGSHOT_SVC_IDS%%,*}
                export SLINGSHOT_DEVICES=${SLINGSHOT_DEVICES%%,*}
                exec bedrock "$@"
            ' bedrock "$MOFKA_PROTOCOL" -c "$RUNTIME" -v info > bedrock.log 2>&1 &
        ;;
    *)
        bedrock "$MOFKA_PROTOCOL" -c "$RUNTIME" -v info > bedrock.log 2>&1 &
        ;;
esac
echo $! > bedrock.pid

for _ in $(seq 1 120); do [ -f mofka.json ] && break; sleep 1; done
[ -f mofka.json ] || { echo "ERROR: mofka.json never appeared; see $MOFKA_SERVER_DIR/bedrock.log"; tail -20 bedrock.log; exit 1; }

mofkactl topic create "$MOFKA_TOPIC" --groupfile mofka.json 2>/dev/null || true
extra=(); [ "$MOFKA_PARTITION_TYPE" = default ] && extra=(--abt-io io_controller)
for p in $(seq 0 $((MOFKA_PARTITIONS - 1))); do
    mofkactl partition add "$MOFKA_TOPIC" --rank $((p % MOFKA_NRANKS)) \
        --type "$MOFKA_PARTITION_TYPE" "${extra[@]}" --groupfile mofka.json 2>/dev/null \
        || echo "  WARN: partition add (rank $((p % MOFKA_NRANKS)) $MOFKA_PARTITION_TYPE) failed"
done

addr="$("$PY" -c 'import json,sys; print(json.load(open("mofka.json"))["members"][0]["address"])' 2>/dev/null || true)"
echo "mofka up: $addr | topic '$MOFKA_TOPIC' ($MOFKA_PARTITIONS x $MOFKA_PARTITION_TYPE, $MOFKA_NRANKS rank) | groupfile $MOFKA_SERVER_DIR/mofka.json (pid $(cat bedrock.pid))"
