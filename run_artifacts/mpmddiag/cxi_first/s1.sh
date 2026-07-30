#!/bin/bash
cd "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmddiag/cxi_first"
echo "s1 MARK start host=$(hostname -s) PMI_RANK=${PMI_RANK:-unset}" > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmddiag/cxi_first/client.log"
export SLINGSHOT_VNIS=${SLINGSHOT_VNIS%%,*} SLINGSHOT_SVC_IDS=${SLINGSHOT_SVC_IDS%%,*} SLINGSHOT_DEVICES=${SLINGSHOT_DEVICES%%,*};
source "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/env/server.sh" --polaris >/dev/null 2>&1
for _ in $(seq 1 40); do [ -f "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmddiag/cxi_first/mofka.json" ] && break; sleep 1; done
if [ ! -f "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmddiag/cxi_first/mofka.json" ]; then
  echo "client: broker never wrote mofka.json" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmddiag/cxi_first/client.log"
  echo "RC topic=NA part=NA" > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmddiag/cxi_first/client.rc"; exit 3
fi
echo "client: mofka.json seen, attaching" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmddiag/cxi_first/client.log"
mofkactl topic create t_cxi_first --groupfile "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmddiag/cxi_first/mofka.json" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmddiag/cxi_first/client.log" 2>&1; rc1=$?
mofkactl partition add t_cxi_first --rank 0 --type memory --groupfile "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmddiag/cxi_first/mofka.json" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmddiag/cxi_first/client.log" 2>&1; rc2=$?
echo "RC topic=$rc1 part=$rc2" > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmddiag/cxi_first/client.rc"
exit $(( rc1 || rc2 ))
