#!/bin/bash
cd "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec"
echo "s2 MARK start host=$(hostname -s) PMI_SIZE=${PMI_SIZE:-unset} VNIS=[$SLINGSHOT_VNIS]" >&2
echo "s2 (workload) start host=$(hostname -s)" > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/workload.log"
for v in $(compgen -v | grep -E "^(PMI_|PMIX_|PALS_)"); do unset "$v"; done;
export SLINGSHOT_VNIS=${SLINGSHOT_VNIS%%,*} SLINGSHOT_SVC_IDS=${SLINGSHOT_SVC_IDS%%,*} SLINGSHOT_DEVICES=${SLINGSHOT_DEVICES%%,*};
source "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/env/server.sh" --polaris >/dev/null 2>&1
echo "s2 MARK post-strip host=$(hostname -s) PMI_SIZE=${PMI_SIZE:-unset} VNIS=[$SLINGSHOT_VNIS]" >&2
for _ in $(seq 1 90); do [ -f "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/CONSUMER_READY" ] && break; sleep 1; done
if [ ! -f "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/CONSUMER_READY" ]; then
  echo "workload: CONSUMER_READY never appeared" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/workload.log"
  echo "RC list=NA create=NA" > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/workload.rc"
  exit 3
fi
echo "workload: CONSUMER_READY seen -> cross-node RPC from 3rd section (N1)" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/workload.log"
mofkactl topic list --groupfile "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/mofka.json" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/workload.log" 2>&1; rc1=$?
mofkactl topic create t_probe_wl --groupfile "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/mofka.json" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/workload.log" 2>&1; rc2=$?
echo "RC list=$rc1 create=$rc2" > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/workload.rc"
exit $(( rc1 || rc2 ))
