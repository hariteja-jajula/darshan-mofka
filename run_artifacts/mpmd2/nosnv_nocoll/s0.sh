#!/bin/bash
cd "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd2/nosnv_nocoll"; rm -f mofka.json
echo "s0 RAW VNIS=[$SLINGSHOT_VNIS] host=$(hostname -s)" >&2

source "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/env/server.sh" --polaris >/dev/null 2>&1
exec bedrock ofi+cxi -c "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd2/nosnv_nocoll/bedrock-config.json" -v info > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd2/nosnv_nocoll/broker.log" 2>&1
