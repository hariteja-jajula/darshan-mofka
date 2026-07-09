#!/bin/bash
# One-shot end-to-end smoke test for the darshan -> mofka connector.
#
#   io_test --(LD_PRELOAD libdarshan)--> darshan-mofka connector
#           --> diaspora-c (fork) --> bedrock topic "darshan" --> consumer
#
# Usage:  bash server/smoke-test.sh [expected_event_count]   # default 51
# Safe to run on a compute node or the login node. Prints PASS/FAIL.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/server/env.sh"
WANT="${1:-51}"

echo "############################################################"
echo "# host        : $(hostname)"
echo "# darshan lib : $(darshan_lib)"
echo "# diaspora-c  : $DIASPORA_C"
echo "# bedrock     : $(command -v bedrock || echo MISSING)"
echo "# python      : $PY"
echo "############################################################"

echo; echo "### [1/4] start bedrock broker"
bash "$ROOT/server/start-server.sh" || { echo ">>> SMOKE FAIL: broker did not start"; exit 1; }

echo; echo "### [2/4] run darshan-instrumented io_test (producer)"
bash "$ROOT/workloads/run.sh"

echo; echo "### [3/4] consume events from topic 'darshan'"
out="$(timeout 60 "$PY" "$ROOT/server/consume.py" "$ROOT/server/mofka.json" darshan "$WANT" 2>&1)"
echo "$out"

echo; echo "### [4/4] stop bedrock broker"
bash "$ROOT/server/stop-server.sh"

echo
if echo "$out" | grep -q "received $WANT events"; then
    echo "================= SMOKE TEST: PASS ($WANT/$WANT events) ================="
    exit 0
else
    echo "================= SMOKE TEST: FAIL ================="
    exit 1
fi
