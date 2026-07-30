#!/bin/bash
cd "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmdnopmi/tcp_nopmi"
echo "s1 MARK start host=$(hostname -s) PMI_SIZE=${PMI_SIZE:-unset}" > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmdnopmi/tcp_nopmi/client.log"
for v in $(compgen -v | grep -E "^(PMI_|PMIX_|PALS_)"); do unset "$v"; done;

source "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/env/server.sh" --polaris >/dev/null 2>&1
for _ in $(seq 1 40); do [ -f "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmdnopmi/tcp_nopmi/mofka.json" ] && break; sleep 1; done
if [ ! -f "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmdnopmi/tcp_nopmi/mofka.json" ]; then
  echo "client: broker never wrote mofka.json" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmdnopmi/tcp_nopmi/client.log"
  echo "RC topic=NA part=NA" > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmdnopmi/tcp_nopmi/client.rc"; exit 3
fi
echo "client: mofka.json seen -> attaching over ofi+tcp" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmdnopmi/tcp_nopmi/client.log"
mofkactl topic create t_tcp_nopmi --groupfile "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmdnopmi/tcp_nopmi/mofka.json" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmdnopmi/tcp_nopmi/client.log" 2>&1; rc1=$?
mofkactl partition add t_tcp_nopmi --rank 0 --type memory --groupfile "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmdnopmi/tcp_nopmi/mofka.json" >> "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmdnopmi/tcp_nopmi/client.log" 2>&1; rc2=$?
echo "RC topic=$rc1 part=$rc2" > "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/mpmdnopmi/tcp_nopmi/client.rc"
exit $(( rc1 || rc2 ))
