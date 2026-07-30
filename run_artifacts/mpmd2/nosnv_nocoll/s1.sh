#!/bin/bash
cd "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd2/nosnv_nocoll"
echo "s1 RAW VNIS=[$SLINGSHOT_VNIS] host=$(hostname -s)" > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd2/nosnv_nocoll/client.log"

source "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/env/server.sh" --polaris >/dev/null 2>&1
for _ in $(seq 1 45); do [ -f "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd2/nosnv_nocoll/mofka.json" ] && break; sleep 1; done
if [ ! -f "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd2/nosnv_nocoll/mofka.json" ]; then
  echo "client: broker never wrote mofka.json" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd2/nosnv_nocoll/client.log"
  echo "RC topic=NA part=NA" > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd2/nosnv_nocoll/client.rc"; exit 3
fi
mofkactl topic create t_nosnv_nocoll --groupfile "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd2/nosnv_nocoll/mofka.json" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd2/nosnv_nocoll/client.log" 2>&1; rc1=$?
mofkactl partition add t_nosnv_nocoll --rank 0 --type memory --groupfile "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd2/nosnv_nocoll/mofka.json" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd2/nosnv_nocoll/client.log" 2>&1; rc2=$?
echo "RC topic=$rc1 part=$rc2" > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmd2/nosnv_nocoll/client.rc"
exit $(( rc1 || rc2 ))
