# Polaris Handoff — darshan-mofka (`polaris-work` branch)

**For the next agent taking over the Polaris side.** Read this top-to-bottom first.
This documents the Polaris work; the LCRC agent's plan/state is in the separate
`progress.md` (theirs, about `feature/restructure-overnight`). Do not conflate them.

Last updated: 2026-07-23.

---

## 0. TL;DR — where things stand

- **Branch you work on: `polaris-work`** (on `origin`). It contains the full LCRC
  restructure PLUS all Polaris work. It is 20 commits ahead of
  `origin/feature/restructure-overnight`, 0 behind, and 33 ahead of `origin/main`.
- The old `polaris-verify` branch was **deleted** (rewritten into `polaris-work`
  with the `Co-Authored-By` trailers stripped — author is `hariteja-jajula`
  throughout). Do NOT recreate polaris-verify. Commit with **no co-author trailer**.
- **The e2e works on Polaris and is proven** (6 `INGEST: PASS` runs on compute
  nodes). Full results in `docs/POLARIS_RESULTS.md`. From-scratch reproducibility
  status in `docs/FROM_SCRATCH_STATUS.md`.
- Everything is pushed. Working clone lives on eagle (see §2).

---

## 1. What this repo is (30-second model)

Darshan runtime I/O events → (connector) → Mofka broker → FlowCept consumer →
MongoDB; a partial `.darshan` log can be reconstructed from the stream. Two
deliverables with different bars:
- `darshan/` submodule = the **connector** (upstream-PR bound).
- everything else = the **demo/reproducibility harness**.

Pipeline entry point is `job.sh` (single-node e2e). It sources `server/env.sh`,
starts a broker (`server/start_server.sh`), runs a FlowCept consumer
(`Client/capture_flowcept.sh`), runs a Darshan-instrumented workload, exports
Mongo → JSONL (`Client/export_jsonl.py`), verifies, and reconstructs.

---

## 2. How to read the current state / get a working shell

**Working clone (already built, on eagle):**
```
/eagle/radix-io/hjajula/pv/darshan-mofka        # on branch polaris-work
```
It must live on eagle (compute nodes can't see /home). The env resolves the
pre-built Mofka stack from eagle automatically.

**Orient yourself:**
```bash
cd /eagle/radix-io/hjajula/pv/darshan-mofka
git status -sb && git log --oneline -5
source server/env.sh          # config-driven; resolves profile=polaris from install/config.yaml
echo "$MOFKA_SPACK_VIEW $PY $MONGOD"   # should all resolve (view has bedrock)
bash check-deps.sh            # PRESENT/MISSING per dependency
```

**Fresh clone from scratch (reviewer flow), if you want to reproduce cleanly:**
```bash
git clone https://github.com/hariteja-jajula/darshan-mofka.git
cd darshan-mofka && git checkout polaris-work
git submodule update --init --recursive
DARSHAN_MOFKA_PROFILE=polaris bash install/setup.sh   # builds the WHOLE stack from source (~1-2h, login node)
bash job.sh                                            # on a compute node
```
A fully-from-scratch build of this kind was done and its e2e PASSED (job 7273625) —
see `docs/FROM_SCRATCH_STATUS.md`.

---

## 3. Ground truth (verified paths on Polaris)

- Pre-built Mofka spack view (bedrock + mofkactl + mochi.mofka): `/eagle/radix-io/hjajula/mofka_tests/spack/var/spack/environments/flowcept-mofka-polaris/.spack-env/view`
- Consumer venv (flowcept + pymongo + pandas, py3.14): `/eagle/radix-io/hjajula/envs/flowcept-py314`
- mongod 7.0.34: `/eagle/radix-io/hjajula/miniconda3_polaris/envs/cll-mongo/bin/mongod` (symlinked into `server/_mongo_env/bin/mongod`)
- From-scratch self-built stack: `/eagle/radix-io/hjajula/from-scratch-repro` (its env resolves its own `install/_spack` view)
- Allocation `radix-io`, ~8,600 NH available. Queues: `debug` (≤2 nodes, 1h, 1 running/user), `debug-scaling` (≤10 nodes, 1h). **PBS `generic` per-user cap = 1 job in Q state**, so queue one at a time (debug and debug-scaling count together for the Q cap).
- Polaris multi-node MPI launch = PALS `mpiexec --ppn 1` (NO ssh). cray-mpich 8.1.28.

**Gotchas that will bite you:**
- `DARSHAN_MOFKA_ENABLE` is a getenv **presence** check (darshan-core.c:357) — `=0`
  does NOT disable it. To turn the connector OFF, `env -u DARSHAN_MOFKA_ENABLE`.
- The authoritative job log is the PBS **`.oNNNN`** file, NOT the tee'd
  `results/*/job.out` (that truncates on process exit). Monitors that read result
  files right at job end race the final flush — sleep ~8-10s first.
- `qstat -x` column layout differs for Q vs R rows; parse state with
  `qstat -xf JID | awk -F'= ' '/job_state/{print $2}'`, not a positional field.
- Login nodes kill long-lived daemons and sustained CPU — run brokers/builds on
  compute nodes or in tmux. `nohup &` gets reaped; use tmux.

---

## 4. What the LCRC restructure changed (so the layout makes sense)

The LCRC agent restructured the repo on `feature/restructure-overnight`:
- New `env/` split (`_profile.sh, common.sh, polaris.sh, lcrc.sh, server.sh,
  workload.sh`) — **currently DEAD** (nothing sources it; the live env is
  `server/env.sh` → `server/env_{polaris,lcrc}.sh`). See §6 open item.
- Moved server scripts: `start-server.sh`→`server/start_server.sh`,
  consumer/export → `Client/`. This broke `job.sh` (it still called old paths);
  **I fixed that** (commit "repair moved-file paths").
- `install/setup.sh` collapsed the phased installers into one.
- `run_overnight.sh` = the LCRC agent's Claude-Code driver loop (leave it alone).

---

## 5. What I did on Polaris (all committed to `polaris-work`)

Fixes (each verified on a compute node, exit 0):
1. **Repaired moved-file paths** in job.sh/jobs/job.sh/Client — e2e was broken on
   both clusters.
2. **Config-driven `cluster:` knob** in `install/config.yaml` (single source of
   truth) + centralized profile resolution in `server/env.sh`; removed the 4×
   duplicated hostname detection.
3. **`install/setup.sh`: install from the committed `spack.lock`**, not `spack
   concretize -f` (which ignored the pin).
4. **`spack.yaml`: `mercury~hwloc`** — the mochi spack `mercury` package declares
   a `hwloc` variant but omits `depends_on('hwloc', when='+hwloc')`, so `+hwloc`
   fails cmake ("Could NOT find HWLOC") in a from-scratch build. `~hwloc` is the
   fix (hwloc there is only NIC topology, unused). Regenerated the lock.
5. **`env_polaris.sh`: prefer repo-local `install/_spack` view + venv** (so a
   from-scratch clone is self-contained), and **version-sort (`sort -V`) the
   gcc-runtime glob** — plain sort picked ancient gcc-8 libstdc++ (no
   GLIBCXX_3.4.32) and broke diaspora-c at load.
6. **`start_server.sh` partition knobs** (`MOFKA_PARTITIONS/NRANKS/PART_TYPE`);
   `default` type now passes `--config.path` (required) and add-errors are no
   longer swallowed.
7. **`server/start_server.mpi.sh`** — multi-node broker via flock `bootstrap:mpi`
   + PALS mpiexec.
8. New workloads: `workloads/c/mofka_forward_loop.c` (heavy, for throughput),
   `workloads/python/io_ml.py` (ML-style I/O), `workloads/c/analyze.py` (timing
   parser; health gate = init+finalize present + no errors + push_mean>0, NOT
   send-count).

Experiments (results in `docs/POLARIS_RESULTS.md`), PBS scripts in `jobs/`:
- e2e: `jobs/e2e_polaris.pbs` — jobs 7273369, 7273397, from-scratch 7273625.
- overhead (C): `jobs/overhead_polaris.pbs` — job 7273451 (~32 µs/push).
- partition curve: `jobs/partsweep_polaris.pbs` — job 7274951 (memory+default,
  flat ~20-22k evt/s).
- MPI broker ingest: `jobs/mpi_broker_polaris.pbs` — job 7273475 (2-node INGEST PASS).
- MPI throughput: `jobs/mpi_throughput_polaris.pbs` — job 7274785 (flat ~19k).
- overhead (python): `jobs/overhead_python_polaris.pbs` — job 7275260 (io_ml,
  +314%, ~32 µs/push, all reps PASS).

Headline scientific finding: throughput is **producer-bound** — a single producer
plateaus at ~20k events/s regardless of partition count or number of broker nodes.
Raising it needs MULTIPLE concurrent producers, not more partitions. Per-push cost
~32 µs.

---

## 6. Open items / suggested next work (for you)

1. **Multi-producer throughput** (the real scaling experiment): run N ranks each
   with the connector against the (proven) 2-node MPI broker; that's where
   partition parallelism should finally help. Use `debug-scaling`.
2. **LCRC multi-node**: LCRC uses OpenMPI, whose default remote launch is **ssh**
   (fails on compute allocations — that's the "ssh error" seen there). Fix:
   `mpirun --mca plm tm ...` (launch through PBS, no ssh). `start_server.mpi.sh`
   currently only does the Polaris/PALS path; add an LCRC branch. Needs LCRC to test.
3. **Dead `env/` split** (165 LOC): biggest remaining LOC cut. Either wire it in
   (replace `server/env*.sh`) or delete it. Left undone because it collides with
   the LCRC agent's in-flight P2 — decide the direction first.
4. **Upstream the mercury~hwloc fix** to the mochi spack repo (`depends_on('hwloc',
   when='+hwloc')`) — it's a genuine upstream bug.
5. **`EVALUATION.md`** at repo root is marked "not committed" but is tracked — the
   evaluation doc flags this for cleanup.

---

## 7. Conventions

- Commit as `hariteja-jajula`, **no `Co-Authored-By` trailer**.
- New PBS results → `results/<name>_<jobid>/` (gitignored); copy the `.oNNNN` in.
- Charge `radix-io`; smallest walltime that fits; queue one job at a time.
- Never break the known-good e2e; re-run `job.sh` (or `jobs/e2e_polaris.pbs`) after
  structural changes before moving on.
