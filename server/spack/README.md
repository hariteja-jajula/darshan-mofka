# Rebuilding the Mofka / FlowCept stack (LCRC + Polaris)

The cluster profile (`env/lcrc.sh` / `env/polaris.sh`) expects a **built Spack view**
containing Bedrock, the Mochi libraries (margo, mercury, thallium, warabi, yokan,
flock), Mofka, and Darshan. Those binaries are ~1 GB of compiled artifacts and are
**not** committed. This directory holds the dependency spec so you can rebuild them
natively:

- `spack.yaml` — the Polaris environment spec (compiler, MPI, externals, package requirements).
- `spack-lcrc.yaml` — the LCRC/Improv spec (system Open MPI with `--with-tm`, verbs transport).
- `spack.lock` — the exact concretized versions from the validated build (fully pinned).

Use the spec that matches your cluster in place of `spack.yaml` in the steps below
(e.g. `server/spack/spack-lcrc.yaml` on LCRC).

## Build

```bash
# 1. get spack (any recent 0.22+/1.x)
git clone --depth=1 https://github.com/spack/spack.git
. spack/share/spack/setup-env.sh

# 2. create + activate the environment from this spec
spack env create flowcept-mofka-polaris server/spack/spack.yaml
spack env activate flowcept-mofka-polaris

# 3. edit spack.yaml: set develop.mofka.path to your mofka source checkout
#    (a clone of https://github.com/mochi-hpc/mofka). Mofka is built from source so
#    the connector patch is included.

# 4. build. Use -j4 on a Polaris login node (higher -j trips the login fork cap:
#    "tar: Cannot fork"); on a compute node you can raise it.
spack install -j4
```

## Point the demo at it

```bash
export MOFKA_SPACK_VIEW="$(spack location --env flowcept-mofka-polaris)/.spack-env/view"
source env/server.sh --polaris
```

`env/polaris.sh` honors `$MOFKA_SPACK_VIEW`, so once it points at this view the rest of
the README works unchanged.

## Notes

- Compiler is `gcc@12.3.0` (`/usr/bin/gcc-12`), the ALCF-supported Polaris system gcc.
- MPI is Cray MPICH (`/opt/cray/pe/mpich/8.1.28/ofi/gnu/12.3`); `libfabric` and
  `rdma-core` are Polaris PE externals. Everything else builds from source.
- `cmake`, `hwloc`, and `pkgconf` are built from source on purpose (Polaris lacks the
  dev headers / ships `pkg-config` rather than `pkgconf`).
- To reproduce the exact validated versions instead of re-concretizing, use the
  committed `spack.lock` (`spack env create <name> spack.lock`).
- The Python side (mochi-margo, flowcept, pymongo, …) lives in a separate venv; see the
  top-level README. `flowcept` itself is the pinned submodule under `flowcept/`.
