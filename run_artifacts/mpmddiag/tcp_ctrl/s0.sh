#!/bin/bash
cd "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmddiag/tcp_ctrl"; rm -f mofka.json
echo "s0 MARK start host=$(hostname -s) RAW_VNIS=[$SLINGSHOT_VNIS] PMI_RANK=${PMI_RANK:-unset} PMI_SIZE=${PMI_SIZE:-unset} PALS_RANKID=${PALS_RANKID:-unset}" >&2

source "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/env/server.sh" --polaris >/dev/null 2>&1
echo "s0 MARK sourced; bedrock=$(command -v bedrock)" >&2
echo "s0 MARK launching bedrock (ofi+tcp)" >&2
exec bedrock ofi+tcp -c "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmddiag/tcp_ctrl/bedrock-config.json" -v trace > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmddiag/tcp_ctrl/broker.log" 2>&1
