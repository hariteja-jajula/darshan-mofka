#!/bin/bash
cd "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmdnopmi/tcp_nopmi"; rm -f mofka.json
echo "s0 MARK start host=$(hostname -s) VNIS=[$SLINGSHOT_VNIS] PMI_SIZE=${PMI_SIZE:-unset}" >&2
for v in $(compgen -v | grep -E "^(PMI_|PMIX_|PALS_)"); do unset "$v"; done;

source "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/env/server.sh" --polaris >/dev/null 2>&1
echo "s0 MARK post-strip PMI_SIZE=${PMI_SIZE:-unset} VNIS=[$SLINGSHOT_VNIS]; launching bedrock (ofi+tcp)" >&2
exec bedrock ofi+tcp -c "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmdnopmi/tcp_nopmi/bedrock-config.json" -v info > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmdnopmi/tcp_nopmi/broker.log" 2>&1 < /dev/null
