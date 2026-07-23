# Independent evaluation — darshan-mofka (branch feature/overnight-lcrc)

Date: 2026-07-23. Reviewer: independent pass, claims verified against files, not
against MORNING_REPORT.md / progress.md.

## Verdict

The actual upstream deliverable — the Darshan connector — is genuinely good and the
headline result is real. `darshan-mofka.c/.h` is compact (265+42 LOC), fully
`HAVE_MOFKA`-gated, has no hardcoded paths, escapes its JSON, bounds every buffer,
and touches darshan-core in ~9 gated lines; it is plausibly upstream-mergeable after
a short polish list. The end-to-end PASS is not hand-wavy: the reconstructed and
native parser dumps are byte-identical across all 144 counter lines except the mount
label, and a genuinely-fresh from-scratch clone reproduced `VERDICT: PASS`. Honesty
is largely sound: the MPI block, the python-ml OPENS gap, and the multi-node broker
failure are all real and documented, and every spot-checkable claim (flowcept pinned
to a SHA, no vendored uthash, no AI co-author trailer, overhead numbers) held up.
**But the overnight run worked directly against the two stated user priorities.** It
committed ~5,600 LOC of run artifacts — scheduler logs, OpenMPI segfault dumps full
of `/home/hjajula/mofka_tests/...` paths, and a 27 KB compiled binary — so a clean
clone now ships author-specific state; and it grew the harness from 37 to 83 files
(55 even net of artifacts) when the explicit goal was fewer files and a smaller diff.
The engineering advanced; the repo hygiene and reviewability regressed.

## Scores

| Dimension | Score | One-line justification |
|---|:---:|---|
| Reproducibility | 3 / 5 | From-scratch build path is real and verified (no `~/mofka_tests` hard dep; it is a soft fallback), submodules SHA-pinned — but committed artifacts leak `/home/hjajula` paths into every fresh clone and `run_overnight.sh` hardcodes author home/scratch. |
| Reviewability / size | 2 / 5 | Grew instead of shrank: 83 files (2.2x the 37 baseline), ~5,643 LOC of committed junk, +18 source/doc files and ~+2,100 LOC net of junk. Connector staying tight is the only thing keeping this off a 1. |
| Connector quality | 4 / 5 | Clean, gated, safe buffers, minimal hooks, reuses darshan machinery. One real (acknowledged, deferred) robustness hole: silent event drop / hex truncation with no counter; handle leak on clean finalize. |
| Docs clarity | 4 / 5 | READMEs read like a human wrote them — plain, motivation-first, no agent-review prose. Docked for a wrong SCHEMA contract, a stale RUNBOOK path, and a self-contradicting `common.sh` comment. |
| Honesty of status | 4 / 5 | Failures are stated plainly and the verifiable claims check out. Docked for over-reading single-sample timing data and a wrong MPI root-cause comment (below). |

## Top 5 issues to fix next (most important first)

1. **Committed run artifacts leak author paths and bloat the tree.**
   `i001.0.1772398` … `i001.3.1788949` (12 files, repo root) are OpenMPI crash
   backtraces containing `/gpfs/fs1/home/hjajula/mofka_tests/...`; `results/*.OU`
   (13 files) are PBS scheduler logs; `workloads/mpi/mofka_forward_mpiio` is a
   tracked ELF binary. Together ~5,643 LOC. `submit.sh:28` writes `.OU` into
   `results/`, and `.gitignore` only ignores `results/*/` (subdirs) and `*.o[0-9]*`,
   not `*.OU` at the results root, so they got committed. This is the single biggest
   hit to *both* stated priorities. Fix: `git rm` all of them, add
   `results/*.OU`, `/i001.*`, and `/workloads/mpi/mofka_forward_mpiio` to
   `.gitignore` (the last is only listed under a different name at `.gitignore`).

2. **Author working-state committed into a reviewer artifact.**
   `run_overnight.sh` (the unattended Claude-Code driver loop; `run_overnight.sh:9`
   and `:78` hardcode `/home/hjajula/...` and `/lcrc/globalscratch/hjajula`),
   `progress.md` (716 lines), `MORNING_REPORT.md`, and `EVALUATION.md` are all
   tracked. `EVALUATION.md:6` even claims it is "intentionally git-ignored" while
   being committed. None of these belong in a clean-clone reproducibility/PR repo;
   removing them is most of the file-count reduction the goal actually asked for.

3. **The documented event schema does not match what the connector emits.**
   `docs/SCHEMA.md:72-73` says FlowCept *adds* `task_id` and `activity_id`, but the
   connector emits both directly (`darshan-mofka.c:198-200`), and the emitted `type`
   field is not documented at all. SCHEMA.md bills itself as "the contract shared by
   three pieces of code," so being wrong here is worse than being silent. Fix the
   attribution and add `type`.

4. **Silent data-loss path in the connector (upstream blocker).**
   `darshan-mofka.c:223` (`if (n < 0 || (size_t)n >= sizeof(buf)) goto out;`) drops
   the entire event with no stderr message and no counter when the JSON exceeds the
   8192-byte buffer; `hex_into` (`darshan-mofka.c:70-80`) silently truncates any
   record whose hex exceeds `rec_hex[4096]` (~2047 raw bytes), which would corrupt
   reconstruction of that record. This is listed as deferred, but it is the one real
   robustness gap and contradicts the "no silent data loss" goal — add a
   dropped-record counter / warning before the PR.

5. **A study conclusion and a code comment overstate what the data supports.**
   The report calls "2 partitions the sweet spot" from `study/multinode.sh` Part B,
   but those walltimes are single-sample (n=1: 0.77 / 0.41 / 0.41 s) while
   `study/overhead.sh` measures ~0.33 s stddev on the same workload — the difference
   is within noise. Separately, `job.sh:129-131` attributes the MPI segfault to the
   node's Yama/shared-memory (vader) setting and forces `--mca btl tcp,self` to
   "fix" it, but the committed tcp-only run
   (`results/mpi_20260723_013256/workload.err`) still segfaults inside
   `mca_btl_tcp_component_init` → `MPI_Init`, so that root-cause is wrong.
   `study/multinode.sh:62` also sets `OMPI_MCA_plm_rsh_args` where openmpi-4.1.8/PRRTE
   needs `PRTE_MCA_plm_rsh_args`, so its host-key mitigation is a silent no-op.

## Claimed but not verifiable / looks wrong

- **"2 partitions is the sweet spot" (multinode).** Not statistically supported
  (n=1 per config, difference inside the measured noise band). Overstated.
- **MPI crash root-cause = Yama/CMA shared memory (`job.sh` comment).** Contradicted
  by the committed tcp-only run still crashing in the TCP BTL init. The *report's*
  higher-level framing ("blocked under LD_PRELOAD; use link-not-preload") is fine;
  the specific in-code attribution is not.
- **`common.sh:5-10`** states the libstdc++ pin is "not needed … therefore dropped,"
  yet `common.sh:44-49` defines `cxx_runtime_pin` and `server.sh:39` /
  `workload.sh:21` call it. The comment is stale and self-contradicting (the pin was
  restored; the header was never updated).
- **`EVALUATION.md:6`** "intentionally git-ignored" — false; the file is tracked.
- **~0.38 node-hours used** — plausible but unverifiable from the tree; not chased.

## What genuinely checks out (credit where due)

- **e2e PASS is real.** `results/c_20260723_004401/`: reconstructed `r.txt` vs native
  `n.txt` are identical on all 144 counter lines once the mount-label column is
  masked (`POSIX_BYTES_READ=20`, matching record IDs, etc.). The `job.sh` compare
  (lines 201-240) is meaningful, not trivial — it sums real per-op counter *values*;
  the python-ml MISMATCH (OPENS 37 vs 48) proves the oracle can fail.
- **From-scratch reproduction is real.** `/home/hjajula/repro-fromscratch/` built the
  Mofka stack from source and its clone's e2e (`results/c_20260723_011225/`) passed
  with the same op-totals and no `~/mofka_tests` reference.
- **Submodules pinned by SHA**, no `branch=` in `.gitmodules`; flowcept at a fixed
  commit. **No AI co-author trailer** in any branch commit (0 matches).
- **"No vendored uthash" is correct** — `darshan-mofka-reconstruct.c:27` includes
  `uthash-1.9.2/src/uthash.h`, the same upstream copy every sibling darshan-util tool
  uses; nothing new was vendored.
- **Overhead numbers are honest** and match `results/overhead_20260723_005801/
  summary.txt` (init ~275 ms, finalize 355-663 ms, push ~40 µs); the "fixed
  startup/shutdown tax, negligible per-op" framing is fair.
- **Connector build integration is minimal and gated** (`build.sh` uses
  `--with-diaspora-c`; `darshan-core.c:356-358,772-773` are the only hooks), and the
  **sub-READMEs read like a person wrote them**, which was an explicit ask.
- **spack-lcrc.yaml's `/gpfs/fs1/soft/improv/...` paths are system software
  installs**, not author paths — appropriate for a cluster-specific spec, with
  `__SPACK_REPOS__` substituted at runtime.
