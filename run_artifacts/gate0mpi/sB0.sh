#!/bin/bash
cd "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/gate0mpi"; rm -f mofka.json
echo "sB0 bedrock start host=$(hostname -s) PMI_SIZE=${PMI_SIZE:-unset}" >&2
for v in $(compgen -v | grep -E "^(PMI_|PMIX_|PALS_)"); do unset "$v"; done;
export SLINGSHOT_VNIS=${SLINGSHOT_VNIS%%,*} SLINGSHOT_SVC_IDS=${SLINGSHOT_SVC_IDS%%,*} SLINGSHOT_DEVICES=${SLINGSHOT_DEVICES%%,*};
source "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/env/server.sh" --polaris >/dev/null 2>&1
echo "sB0 post-strip PMI_SIZE=${PMI_SIZE:-unset}; launching bedrock" >&2
exec bedrock ofi+cxi -c "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/gate0mpi/bedrock-config.json" -v info > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/gate0mpi/broker.log" 2>&1 < /dev/null
