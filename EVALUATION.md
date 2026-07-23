# EVALUATION.md (local, not committed)

Evaluation framework for darshan-mofka: reproducibility, compactness/reviewability,
clarity, instruction quality, and upstream-merge readiness.

This file is intentionally git-ignored (see `.gitignore`). It is a working
scorecard for the author and for anyone deciding whether the Darshan connector is
ready to PR upstream and whether this harness is a reproducible artifact.

Date: 2026-07-22

---

## 0. What is being evaluated (two artifacts, two bars)

There are two separate deliverables with different acceptance bars. Do not conflate
them.

1. **The Darshan fork (`darshan/` submodule) — the connector.**
   Files: `darshan-runtime/lib/darshan-mofka.c/.h`, the `DARSHAN_MOFKA_SEND` hooks
   in `darshan-{posix,stdio,mpiio,hdf5}.c`, `maint/config/check_diaspora_c.m4`,
   and `darshan-util/darshan-mofka-reconstruct.c`.
   **This is what should merge upstream into `darshan-hpc/darshan`.**
   Bar: *would a Darshan maintainer accept this PR.*

2. **The integration/harness repo (`darshan-mofka/`) — everything else.**
   Build/env/server/consumer scripts, workloads, install automation, docs.
   **This is a demo/reproducibility harness, not upstream Darshan.**
   Bar: *can an independent reviewer clone and reproduce the headline result on a
   fresh allocation, with no author-specific state.*

Established from reading the code, the connector is already architecturally
upstream-shaped: a near-exact clone of the upstream LDMS `darshanConnector`
side-channel pattern (`initialize` / `send`, plus a `finalize`), ~9 lines touched
in `darshan-core.c`, fully `HAVE_MOFKA`-gated (non-Mofka build is byte-identical),
no TODO/FIXME or hardcoded paths in source. The remaining gaps are: **size/LOC
reduction for reviewability, documentation, a few style deviations, and a couple
of robustness fixes.** All narrow and low-risk.

---

## 1. Size and reviewability (PRIMARY axis: reduce files and LOC)

Reviewability is the single most important property for landing a PR. A reviewer's
willingness and ability to accept the change is roughly inversely proportional to
the diff size and the number of new files. **Reducing file count and lines of code
is therefore a first-class goal, not cleanup.** Smaller diff => faster review =>
higher merge probability.

### 1.1 Current measured size

Connector (the upstream-bound diff), new/changed source:

| File | LOC | Notes |
|---|---:|---|
| `darshan-runtime/lib/darshan-mofka.c` | 265 | main connector |
| `darshan-runtime/lib/darshan-mofka.h` | 42 | API + `DARSHAN_MOFKA_SEND` macro |
| `maint/config/check_diaspora_c.m4` | 50 | build gating |
| **connector core subtotal** | **357** | the part a Darshan reviewer must read closely |
| `darshan-util/darshan-mofka-reconstruct.c` | 722 | **largest single reviewable unit** |
| **connector total (new source)** | **~1079** | + ~40 lines of guarded hooks across 4 modules + 3 build files |

Harness (tracked, excluding submodules and `_venv/`):

- **37 tracked files, ~3652 LOC.**
- Largest: `docs/RUNBOOK.md` (534), `progress.md` (411), `job.sh` (273),
  `install/setup.sh` (204), `README.md` (184), `server/capture_flowcept.sh` (131).

### 1.2 Where the LOC/file reduction must happen

**Connector (highest priority — this is the PR):**

- [ ] **`darshan-mofka-reconstruct.c` (722 LOC) is the biggest reviewability risk.**
  It is 2x the size of the actual connector. Reduce by:
  - Deleting the **vendored `uthash-1.9.2/`** copy and using the tree's existing
    `uthash.h` (removes an entire embedded dependency file from the diff).
  - Reusing more `libdarshan-util` helpers instead of hand-rolled logic where a
    library function exists (continue the pattern already started; prior commit
    `fc992b12` reduced ~99 LOC via darshan reuse — keep going).
  - Considering whether the hand-rolled JSON scanner can be shrunk or whether the
    tool can be split so the *reviewable* core is small and the parsing is
    obviously-correct/isolated.
  - Optionally: is the reconstruct tool required in the **first** upstream PR, or
    can the connector land alone and the tool follow as a second, smaller PR?
    Splitting halves the initial review burden.
- [ ] **Do not add new files unless a sibling pattern requires it.** The connector
  already respects this (files live beside their LDMS/util siblings). Keep it.
- [ ] **Keep the core hook diff minimal.** ~9 lines in `darshan-core.c` and
  5-9 lines per module is good; do not grow it.
- [ ] **Collapse the two `AM_CONDITIONAL([HAVE_MOFKA])` definitions** (currently
  defined twice in the m4, false then true) into the standard single grouped
  location — fewer lines, matches upstream.

**Harness (secondary — not upstream, but affects artifact reviewability):**

- [ ] **`docs/RUNBOOK.md` (534) + `README.md` (184) overlap heavily** (the RUNBOOK
  re-states the one-shot block that `job.sh` already automates). Deduplicate: the
  README routes, the RUNBOOK details, `job.sh` is the source of truth. Cut the
  duplicated one-shot block.
- [ ] **`job.sh` (273) vs `jobs/job.sh` (117)** are two job scripts. If `jobs/job.sh`
  is an older variant (per RUNBOOK it is), fold the still-useful DLIO path into
  `job.sh` behind a flag and delete `jobs/job.sh`, or clearly mark it deprecated.
- [ ] **`server/capture.py` (64) vs FlowCept path** — RUNBOOK says `capture.py` is
  "still available as a simple debug drain." If the FlowCept consumer is the real
  path, consider removing `capture.py` to cut a file, or clearly scope it as a
  debug-only helper.
- [ ] **Two env profile files** (`env_polaris.sh` 99, `env_lcrc.sh` 71, `env.sh` 99).
  Reasonable, but audit for duplicated blocks that could move into `env.sh`.

### 1.3 Reduction targets (make them explicit and check them)

Set and track concrete numbers so "reduce LOC" is measurable, not aspirational:

- [ ] Connector new-source total (excl. reconstruct): keep <= ~360 LOC. (now 357 — hold)
- [ ] `darshan-mofka-reconstruct.c`: target a meaningful cut from 722 (e.g. remove
  vendored uthash + reuse => aim < 550), OR split into a follow-up PR.
- [ ] Harness tracked LOC: reduce from ~3652 by deduplicating RUNBOOK/README and
  removing/merging redundant scripts. Target a double-digit-% cut.
- [ ] Harness tracked file count: reduce from 37 where files are redundant.

Rule of thumb for every change from here: **prefer deleting/merging to adding.**
If a change adds a file or grows the diff, justify why reuse was impossible.

---

## 2. Reproducibility

Three tiers; the evaluation must state which is claimed.

- **Tier 0** "works on my machine" (needs `~/mofka_tests/spack`, author `$HOME`).
  Where `progress.md` honestly places the repo today. Not the final bar.
- **Tier 1** "clean clone reproduces on the target cluster" via a documented
  sequence, no hand-copied artifacts, no author `$HOME`. **This is the target.**
- **Tier 2** "bit-for-bit anywhere." Not realistic for a Mofka/Mochi/fabric stack;
  do not claim it.

| # | Criterion | Status | Gap / action |
|---|---|---|---|
| R1 | No path outside the clone is required as input | Partial | `server/env_lcrc.sh` still sources `$HOME/mofka_tests/spack` (known open item) |
| R2 | Every external dep version-pinned | Partial | Polaris `spack.lock` exists; **no `spack-lcrc.lock`** yet |
| R3 | Submodules pin exact commits, not branches | **FAIL** | `flowcept` submodule tracks branch `experiment/f1-v2-unpack-batches` — pin a SHA |
| R4 | No generated artifacts committed | Mostly | `.gitignore` thorough; verify `server/bedrock-config.json` is a template, not runtime output |
| R5 | One documented command reproduces the result | Partial | `bash job.sh` works; the LCRC setup before it is not yet one-command |
| R6 | Result is verifiable, not just runnable | PASS | `job.sh` reconstructs + compares to native, `INGEST: PASS` gate. Keep as oracle. |
| R7 | Determinism boundaries documented | TODO | State which fields are nondeterministic (timestamps, pid, seq) so diffs don't false-fail |

Gold standard: a committed `REPRODUCE.md` (or README section) a reviewer follows
verbatim, ending in a machine-checkable assertion (e.g. expect
`modules: {'POSIX': 4, 'STDIO': 9}` and `INGEST: PASS`). You already produce this
output; promote it from `progress.md` prose to a committed expectation.

---

## 3. Compactness / reuse / structure fidelity

"Compact" = maximal reuse of existing Darshan machinery + minimal new surface, and
new code indistinguishable in shape from what a maintainer would write.

Strengths (keep):
- Connector reuses `darshan_core_lookup_record_name`, `darshan_core_wtime_absolute`,
  `darshan_core_abs_timespec_from_wtime`, `darshan_core_fprintf`.
- Correctly does NOT implement full `darshan_module_funcs` registration — it is a
  side-channel like LDMS, not a log module. Right call.
- Reconstruct tool reuses `libdarshan-util` (`log_put_record`, `darshan_log_put_exe`,
  the `mod_logutils` table).
- New files live beside siblings; build gating mirrors LDMS/HDF5 idiom.

Anti-patterns to fix (also LOC wins, see section 1):
- [ ] Vendored `uthash-1.9.2/` copy in the reconstruct tool — use tree `uthash.h`.
- [ ] Fixed-size stack buffers that silently drop data: `MOFKA_JSON_BUF=8192`
  (event dropped on overflow via `goto out`), `rec_hex[4096]` (caps struct at
  ~2 KB). Compact but lossy — raise/loop/heap or at minimum count-and-report.
- [ ] Reconstruct only handles fixed-size records matching the current build's
  `sizeof`. Compact but brittle; document as a v1 limitation in `--help` + docs.
- [ ] Confirm the "no duplication" claim: `server/spack/spack.yaml` is used by both
  manual and `install/setup.sh` paths (no second drifting copy).

---

## 4. Understandability (overview -> detail)

Judged at three zoom levels; each README must nail its level.

- **Repo level:** top README states what/where (Darshan -> Mofka -> FlowCept ->
  MongoDB -> reconstruct). Good. Missing: a one-diagram mental model (ASCII
  pipeline) and an up-front statement of the real motivation — **partial-log
  recovery when a job dies before Darshan's shutdown writes the log.** That value
  proposition is currently buried.
- **Component level:** sub-READMEs (`workloads/`, `install/`, `server/spack/`) are
  *procedurally precise but overview-thin* — they say *how* before *what this
  component is and how it fits*. **Fix: mandatory 2-3 sentence "What this is /
  where it sits / what it produces" header on every README before any commands.**
- **Code level:** the event JSON schema (`schema:"darshan_runtime"`,
  `schema_version:2`, `rec_hex` semantics) is only discoverable by reading
  `darshan-mofka.c`. **Add one canonical schema reference** (field -> meaning ->
  example) — it's the contract between the C producer, the Python consumer, and the
  reconstruct tool. Highest-leverage doc to add.

| # | Criterion | Status |
|---|---|---|
| U1 | Top README: motivation + data flow + diagram | Partial (no diagram; motivation understated) |
| U2 | Every sub-README begins with what/where/produces before commands | **Missing** |
| U3 | Event JSON schema documented once, referenced everywhere | Missing |
| U4 | Env-var contract documented | PASS (good table in top README) |
| U5 | Docs link up (overview) and down (detail); no dead ends | Mostly |
| U6 | Consistent terminology (connector vs module vs backend) | Needs glossary; "module" overloaded vs Darshan's meaning |
| U7 | Failure modes / troubleshooting discoverable | PASS (RUNBOOK troubleshooting) |

---

## 5. Instruction definiteness

- RUNBOOK is strong: explicit Polaris workarounds (Cray `cc` pkg-config hook,
  eagle/`$HOME` compute-node caveat), expected outputs per step.
- Move toward profile-parameterized, not machine-specific (`--polaris`/`--lcrc`,
  `DARSHAN_MOFKA_PROFILE`). Right direction.
- [ ] Symmetric Polaris/LCRC docs: LCRC is where it currently passes but is a
  second-class inline note. Elevate it to first-class.
- [ ] Give `install/setup.sh` an explicit "what success looks like" output.

---

## 6. Upstream-merge blueprint

### 6.1 Darshan PR (the connector)

Must satisfy all:
1. Scope isolation — new files + minimal guarded hooks only; **no harness/scripts
   in the PR.** (already true)
2. Zero-overhead-when-off, provably (macro no-op, no symbols). (already true) —
   demonstrate both build configs.
3. Build idioms match upstream: group `AM_CONDITIONAL` in `configure.ac` (not in
   the m4, not defined twice); add config-summary line (done); decide
   `--with-diaspora-c` vs also offering `--enable-mofka-mod` (LDMS offers both).
4. **Doc parity with LDMS** (#1 blocker): add Mofka section + `--with-diaspora-c`
   flag + `DARSHAN_MOFKA_*` env table to `darshan-runtime/doc/darshan-runtime.rst`;
   add a `ChangeLog` entry; document the reconstruct tool.
5. Style: fix copyright wording ("University of Chicago", not "The University of
   Chicago"); add emacs/vim mode-line trailer; replace `g_*` globals with a single
   `static struct mofka_runtime`; consider a producer lock (LDMS `ln_lock` parity).
6. Robustness: no silent event drops; gate `darshan-mofka-reconstruct` build on
   `HAVE_MOFKA`; drop vendored uthash; document fixed-size-record limitation.
7. A minimal in-tree test (mock/NULL-broker smoke).
8. Clean, curated, rebased history on a feature branch (not `main`); ~31 mofka
   commits squashed into a coherent series (connector / reconstruct / docs / build).
   **Consider splitting: connector PR first, reconstruct tool as a smaller
   follow-up** to cut initial review size.

### 6.2 Harness as a citable artifact

1. `install/setup.sh` builds the **LCRC** stack repo-locally; remove the
   `~/mofka_tests/spack` dependency (add `server/spack/spack-lcrc.yaml` + `.lock`,
   wire profile-specific specs into `install/config.yaml`).
2. Pin the `flowcept` submodule to a SHA.
3. Promote headline result + expected output into a committed `REPRODUCE.md` with a
   pass/fail oracle.
4. Symmetric Polaris/LCRC docs.
5. Remove stray `.out` artifacts; confirm `bedrock-config.json` is a template.
6. Top-of-repo pipeline diagram + motivation up front.
7. State clearly: connector in `darshan/` is the upstream contribution; this repo is
   the demo harness.

---

## 7. Scored rubric

Score each 0-5, multiply by weight. Reviewability/size is weighted heavily because
it is the gating factor for a PR.

| Dimension | Weight | Now | Target |
|---|---:|---:|---:|
| 1. Size / reviewability (fewer files, fewer LOC, small diff) | **20%** | ~3 | 5 |
| 2. Connector correctness & upstream-fit | 18% | ~4 | 5 |
| 3. Reproducibility (tier) | 18% | ~2.5 | 5 |
| 4. Compactness / reuse / structure fidelity | 14% | ~3.5 | 5 |
| 5. Documentation clarity (overview -> detail) | 12% | ~3 | 5 |
| 6. Instruction definiteness | 8% | ~3.5 | 5 |
| 7. Robustness / honesty about limits | 6% | ~2.5 | 5 |
| 8. Hygiene (no artifacts, pinned deps, clean history) | 4% | ~3.5 | 5 |

Current weighted position: **solid working prototype, not yet artifact-grade or
PR-grade.** The hard engineering is done and done well; remaining work is size
reduction, documentation, reproducibility de-coupling from author state, and PR
polish.

---

## 8. Pass/fail gates (binary; must all be true to claim "done")

- [~] **G0 (size)** No vendored deps confirmed (uthash is the tree's shared copy);
      old shims + jobs/job.sh deleted; single-use vars inlined; connector micro-
      reductions vetted + listed for the PR. reconstruct split still a PR follow-up.
- [x] **G1** Clean clone on LCRC reaches `INGEST: PASS` **without `~/mofka_tests`**:
      the full stack builds from source (server/spack/spack-lcrc.yaml) and the P13
      e2e on that from-scratch clone returned `VERDICT: PASS`.
- [x] **G2** `flowcept` submodule pinned to a SHA (branch tracking removed).
- [~] **G3** Non-Mofka build is byte-identical by construction (HAVE_MOFKA-gated);
      not re-demonstrated as a build this run -- keep for the PR.
- [x] **G4** No author `$HOME`/account in tracked files (spec sanitized to a
      placeholder + system externals); generated artifacts gitignored.
- [x] **G5** Every sub-README opens with a plain what/where/produces overview.
- [x] **G6** Event JSON schema documented once in docs/SCHEMA.md, referenced by
      producer + consumer + reconstruct.
- [ ] **G7** Connector docs (rst + ChangeLog) at LDMS parity -- PR follow-up.
- [ ] **G8** No silent data loss (rec_hex/JSON buffer overflow) -- PR follow-up,
      documented with exact locations in the P10 report + progress.md.

---

## 9. Measured baseline (snapshot for tracking reduction)

- Connector new source: `darshan-mofka.c` 265, `.h` 42, `check_diaspora_c.m4` 50,
  `darshan-mofka-reconstruct.c` 722. Core hooks: ~9 lines in `darshan-core.c`,
  5-9 lines each in posix/stdio/mpiio/hdf5. 4 new files + 8 modified.
- Harness: 37 tracked files, ~3652 LOC (excl. submodules and `_venv/`).
- Largest harness files: RUNBOOK 534, progress.md 411, job.sh 273, setup.sh 204,
  README 184, capture_flowcept.sh 131, spack.yaml 130, check-deps.sh 125.

Re-run to refresh:

```bash
# connector source sizes
wc -l darshan/darshan-runtime/lib/darshan-mofka.{c,h} \
      darshan/darshan-util/darshan-mofka-reconstruct.c \
      darshan/maint/config/check_diaspora_c.m4

# harness file count + LOC (excl submodules and venv)
git ls-files | grep -vE '^(darshan|diaspora-stream-api|flowcept)/' | grep -vE '_venv/' | wc -l
git ls-files | grep -vE '^(darshan|diaspora-stream-api|flowcept)/' | grep -vE '_venv/' \
  | while read f; do wc -l < "$f"; done | awk '{s+=$1} END{print s}'
```
