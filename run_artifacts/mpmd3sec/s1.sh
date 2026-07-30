#!/bin/bash
cd "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec"
echo "s1 MARK start host=$(hostname -s) PMI_SIZE=${PMI_SIZE:-unset} VNIS=[$SLINGSHOT_VNIS]" >&2
echo "s1 (consumer) start host=$(hostname -s)" > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/consumer.log"
for v in $(compgen -v | grep -E "^(PMI_|PMIX_|PALS_)"); do unset "$v"; done;
export SLINGSHOT_VNIS=${SLINGSHOT_VNIS%%,*} SLINGSHOT_SVC_IDS=${SLINGSHOT_SVC_IDS%%,*} SLINGSHOT_DEVICES=${SLINGSHOT_DEVICES%%,*};
source "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/env/server.sh" --polaris >/dev/null 2>&1
echo "s1 MARK post-strip host=$(hostname -s) PMI_SIZE=${PMI_SIZE:-unset} VNIS=[$SLINGSHOT_VNIS]" >&2
for _ in $(seq 1 40); do [ -f "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/mofka.json" ] && break; sleep 1; done
if [ ! -f "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/mofka.json" ]; then
  echo "consumer: broker never wrote mofka.json" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/consumer.log"
  echo "RC topic=NA part=NA" > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/consumer.rc"
  touch "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/CONSUMER_READY"
  exit 3
fi
echo "consumer: mofka.json seen -> attaching CXI broker from SAME node" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/consumer.log"
mofkactl topic create t_probe --groupfile "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/mofka.json" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/consumer.log" 2>&1; rc1=$?
mofkactl partition add t_probe --rank 0 --type memory --groupfile "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/mofka.json" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/consumer.log" 2>&1; rc2=$?
echo "RC topic=$rc1 part=$rc2" > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/consumer.rc"
touch "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd3sec/CONSUMER_READY"
exit $(( rc1 || rc2 ))
