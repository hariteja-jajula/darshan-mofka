# From-scratch build status (install/setup.sh, profile=polaris)

**Date:** 2026-07-23 · **Branch:** polaris-verify

## Summary

The **primary reproducibility path works and is proven**: clone the repo, reuse
the pre-built Mofka/Mochi spack stack on eagle (what `check-deps.sh` detects and
`server/env.sh --polaris` wires), build the connector with `build.sh`, run
`job.sh`. This reached `INGEST: PASS` on Polaris compute nodes 5 times tonight
(jobs 7273369, 7273397, 7273451, 7273454, 7273475).

The **fully-from-scratch path** (`install/setup.sh` builds the entire native stack
from source with its own spack clone) was **blocked by an upstream spack packaging
defect** (below) — now **FIXED** by pinning `mercury~hwloc` in server/spack/spack.yaml
+ regenerated spack.lock. Verified: mercury@2.4.1 now builds in the from-scratch
tree (`vui6ist`) where `+hwloc` failed at configure every time. Full-stack build
COMPLETE. `SETUP COMPLETE` (DONE_RC=0), and the **from-scratch e2e PASSED**: job
7273625 (exit 0, 53s) — clone -> submodules -> install/setup.sh (full Mochi/Mofka
stack + mongod + venv + darshan connector all built from source) -> job.sh ->
`INGEST: PASS`, 13 docs, reconstructed OPENS match native. The env now resolves
the repo-local install/_spack view + install/_venv (env_polaris.sh fix), so the
clone is fully self-contained. This closes the git-clone->deps->build->green loop.

## What was fixed in this repo (committed)

`install/setup.sh` used to run `spack concretize -f`, which throws away the
committed `server/spack/spack.lock` and re-solves from scratch. Now it installs
strictly from the committed lock (commits d8f0b12, 5893d65). This is necessary but
not sufficient — see the blocker.

## The blocker: mercury `+hwloc` has no dependency edge (spack pin defect)

`mercury@2.4.1 +hwloc` (in `server/spack/spack.lock`, and in any fresh concretize
with this spack pin `cd9936355`) sets the `+hwloc` variant but **does not declare
`depends_on('hwloc')`**. Verified: the concrete mercury spec's dependency list is
`{cmake, compiler-wrapper, gcc, gcc-runtime, glibc, gmake, libfabric}` — no hwloc,
even with an explicit `^hwloc` in the spec or an hwloc external registered.

At build time mercury's cmake does `-DNA_OFI_USE_HWLOC=ON` and looks for hwloc via
**pkg-config** (`Checking for module 'hwloc'`). Because spack never put hwloc (nor
its transitive `Requires.private: libxml-2.0 pciaccess`) on `PKG_CONFIG_PATH`, the
lookup fails:

```
Could NOT find HWLOC (missing: HWLOC_INCLUDE_DIR HWLOC_LIBRARY)
```

The **pre-built eagle stack has the identical mercury hash (`lyu3h3t`) and the same
lock deps, yet built successfully and links `libhwloc.so.15`** — because when it was
built, hwloc's (and pciaccess's, libxml2's) pkgconfig happened to be ambient on
`PKG_CONFIG_PATH`. The from-scratch env scrubs that, so the same spec fails.

## Fix options (for a follow-up, needs a human decision)

1. **Patch the mercury spack package** (cleanest): add
   `depends_on('hwloc', when='+hwloc')` to mercury's `package.py` in the pinned
   spack, so spack wires hwloc + its pkgconfig into mercury's build env. This edits
   the spack clone, not this repo.
2. **Inject pkgconfig at install time**: before `spack -e ... install`, export
   `PKG_CONFIG_PATH` to include the built hwloc, pciaccess, and libxml2
   `lib/pkgconfig` dirs. Fragile (order/transitive-dep sensitive).
3. **Drop hwloc from mercury**: build `mercury~hwloc` (na/ofi topology awareness is
   optional; the connector's e2e does not depend on it). Smallest change; would let
   the whole from-scratch stack build. Recommended if a self-contained build is the
   goal and hwloc topology isn't needed.

Until one is applied, keep using the pre-built stack (the README's default flow).
