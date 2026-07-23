# Overnight run report — 2026-07-23

Good morning. Here is everything I did overnight, what worked, what didn't, and
what needs your eye. I worked on my own branch and pushed after every step.

- **Branch:** `feature/overnight-lcrc` (off `feature/restructure-overnight`)
- **Everything is committed and pushed.** No AI co-author trailer (you asked me to
  scrub it — I removed it from all my commits on this branch and stopped adding it).
- **Compute used:** ~0.38 node-hours of the 30 budget. Everything ran on the debug
  queue in 1–3 minutes per job. The heavy stack build ran on a login node (free).

## The headline

1. **The end-to-end pipeline works on the new structure.** A clean run streams
   Darshan events through Mofka + FlowCept into MongoDB, rebuilds a partial
   `.darshan` log, and it matches the real one: `INGEST: PASS`, `VERDICT: PASS`.
2. **The whole Mofka stack now builds from scratch — no more `~/mofka_tests`.**
   I built the full native stack (Mofka, Mochi, Bedrock, ~1.3 GB) from source on a
   login node using a committed spec, then ran the e2e on a *fresh clone that uses
   only that from-scratch stack*. It passed. This was the biggest open reproducibility
   gap and it is now closed.
3. **Overhead is measured** and the breakdown is interesting (below).
4. **Everything is grounded in the real Mofka docs** — I downloaded and read them
   (see `docs/MOFKA_NOTES.md`) and used them for the multi-node work; they confirmed
   our single-node config is right.

## What got done, by phase

The restructure (P1–P7) is complete and verified:

- The two-env split (`env/server.sh`, `env/workload.sh`) is now wired into
  everything. I deleted the old `server/env*.sh` shims and `jobs/job.sh` after the
  new path passed e2e.
- `job.sh` was rewritten: it picks a workload (`c`, `mpi`, `dlio`, `python-ml`),
  runs the full pipeline, reconstructs, compares to the native log with a clear
  PASS/MISMATCH verdict, and writes everything into `results/<workload>_<timestamp>/`
  including a pydarshan HTML report.
- New `submit.sh` sends a job to PBS. New `Database/get_mongod.sh` downloads MongoDB.
  New per-folder READMEs, written for people to read.

**One important correction:** a previous cleanup had removed the C++ runtime "pin"
claiming it was unneeded. That was tested only on a login node. On a **compute
node** the FlowCept consumer died with `GLIBCXX_3.4.32 not found`, because the Spack
view puts an older libstdc++ ahead of gcc-13's. I restored the pin, but derived it
from the compiler module (`$CXX -print-file-name`) instead of a hardcoded path, so
it still honors the no-hardcoded-`.so` rule. This is what unblocked the e2e.

## Results you can look at

### End-to-end (C smoke workload) — PASS
`results/c_20260723_004401/` — `INGEST: PASS`, `modules {POSIX:4, STDIO:9}`,
reconstructed op-totals match native exactly, pydarshan HTML rendered.

### Reproducibility from scratch — PASS
The from-scratch stack is at `/home/hjajula/repro-fromscratch/`. The e2e on that
clone passed with `VERDICT: PASS` and no reference to `~/mofka_tests`. Two
cluster-specific build fixes were needed and are baked into `install/setup.sh`:
mercury built `~sm` (this node's Yama setting blocks shared-memory self-test), and
spack fetches via `curl` (the login node's Python can't verify some GNU mirror
certs; sources are still SHA-256 checked). The committed spec is
`server/spack/spack-lcrc.yaml`.

### Overhead (P9) — measured
`results/overhead_20260723_005801/summary.txt`. Three configs × 3 reps, for the C
and python-ml workloads:

- Per-event push cost is **tiny: ~40 µs**.
- The overhead is dominated by **one-time init (~275 ms**, connecting to the broker)
  and the **finalize flush (~350–660 ms**, draining pending batches at shutdown).
- So for these very short workloads the fixed costs dwarf the runtime (the % looks
  huge), but for a real long-running HPC job those fixed costs amortize to near zero.
  The honest takeaway: the connector's *per-operation* cost is negligible; its cost
  is a fixed startup+shutdown tax.

### python-ml workload — streams + reconstructs, with an honest caveat
`results/python-ml_<ts>/`. Full pipeline ran: `python-ml workload complete`,
132 events, `INGEST: PASS`, modules `{POSIX:121, STDIO:11}`. Reconstructed
READS (98) and WRITES (9) match native exactly; OPENS is 37 vs native 48. That gap
is real and informative: python-ml opens ~120 files in a burst, and the last events
(which carry the final counters) don't always drain before the finalize flush
window closes, so the rebuilt counters lag. The C workload (few, spaced events)
matches exactly. This is exactly the "no silent data loss" robustness item (G8) —
the fix is a longer/acknowledged final flush or a dropped-event counter, listed for
the PR. (It also lines up with the overhead finding that finalize is the variable
phase.) The workload itself used the plain-Python path since PyTorch has no 3.14 wheel.

### Multi-node / partitions (P9, your extra ask) — partial
`results/multinode_20260723_011303/`. On a single broker, one sample each:
1 partition 0.77 s, 2 partitions 0.41 s, 4 partitions 0.41 s. Treat this as a hint,
not a result — it's a single run per point and well within run-to-run noise, so I
would not claim a "best" partition count without repeated reps. **The true
multi-node broker (flock MPI bootstrap across 2 nodes) did not come up**: openmpi
tries to launch the second
bedrock over SSH and hits `Host key verification failed` — a site launcher issue,
not a config problem. The exact, doc-grounded recipe for it is in
`docs/MOFKA_NOTES.md` §3c and the config is `server/bedrock-config-mpi.json`; it
needs an MPI launcher that can span nodes here (or SSH between compute nodes enabled).

## What is NOT done, honestly

- **MPI-IO workload runs, doesn't complete.** It builds fine (mpicc + the MPI
  Darshan build), but running it segfaults inside openmpi's `MPI_Init` when
  `libdarshan.so` is `LD_PRELOAD`ed on this node. I made six attempts and ruled out
  the compiler, the launcher-preload, slot counts, and every shared-memory path.
  This is a Darshan-MPI + openmpi-4.1.8 + LD_PRELOAD integration problem specific to
  this cluster, **not** the connector — its MPIIO events use the exact same
  `DARSHAN_MOFKA_SEND` mechanism that POSIX/STDIO already prove. The right fix is
  Darshan's supported MPI mode: **link** libdarshan into the MPI binary (via
  darshan's compiler wrapper) instead of preloading it. I did not want to guess at
  that unattended; it's a clean next step.
- **DLIO workload not run.** `dlio_benchmark` needs heavy deps (TensorFlow/Torch)
  that don't have Python 3.14 wheels. It's documented as optional in
  `workloads/dlio/README.md`.
- **Connector micro-reductions and robustness fixes** (a handful of lines: inline a
  variable, drop an unused include, collapse a duplicated `AM_CONDITIONAL`, fix the
  copyright wording, add a dropped-record counter) are **vetted and listed** in
  `progress.md` and `EVALUATION.md` but deferred to the upstream PR, because they
  need a submodule commit + rebuild + dual-config testing that belongs in reviewed
  PR work, not an unattended pass. Good news from the review: **no vendored uthash**
  (it uses the tree's shared copy), and the connector has **no dead code**.

## New docs I added (all written for humans)

- `README.md` — rewritten: motivation first (recover I/O when a job dies before
  Darshan writes its log), plus an ASCII pipeline diagram.
- `REPRODUCE.md` — build-from-scratch steps ending in the exact expected output.
- `docs/SCHEMA.md` — what one streamed event contains, field by field.
- `docs/MOFKA_NOTES.md` — grounded notes from the official Mofka/Mochi/flock docs.
- READMEs in `env/`, `server/`, `Client/`, `Database/`, `results/`, `workloads/python-ml/`.

## What I'd like you to decide / check

1. **MPI-IO:** OK to switch the MPI workload to link-libdarshan instead of preload?
   That's almost certainly the fix.
2. **Multi-node broker:** is SSH between compute nodes allowed on Improv, or is
   there a preferred MPI launcher? That's all that's blocking the real multi-node study.
3. **The connector PR-polish list** (EVALUATION §"deferred") — want me to apply those
   in the darshan submodule and push to your darshan fork next?
4. The Polaris agent pushed a note to this branch; I integrated it and there's a new
   `origin/polaris-verify` branch — worth a look to see where that side landed.

## Where things live

- Working branch: `feature/overnight-lcrc` (pushed).
- From-scratch reproduction: `/home/hjajula/repro-fromscratch/` (stack + clone + logs).
- Every run's artifacts: `results/<name>_<timestamp>/`.
- Plan + full running log + budget: `progress.md`. Scorecard: `EVALUATION.md`.
