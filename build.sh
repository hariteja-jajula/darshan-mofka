#!/bin/bash
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DARSHAN="$HERE/darshan"
[ -d "$DARSHAN/darshan-runtime" ] || {
    echo "build.sh: no darshan submodule at $DARSHAN (run: git submodule update --init --recursive)"; exit 1; }

# Resolve ENV_PROFILE (polaris|lcrc) up front so the MPI-compiler choice below can
# branch on it. _profile.sh is idempotent and cheap; sourcing it unconditionally means
# a bare `DARSHAN_MPI=1 ./build.sh` (even with DIASPORA_C pre-set, which skips the
# workload.sh source below) still has a well-defined $ENV_PROFILE. (BX 2026-07-27)
if [ -z "${ENV_PROFILE:-}" ] && [ -f "$HERE/env/_profile.sh" ]; then
    # shellcheck disable=SC1091
    source "$HERE/env/_profile.sh"
fi

# DIASPORA_C (the C library the connector links) comes from env/workload.sh. Source
# it here if the caller hasn't, so `./build.sh` works on its own.
if [ -z "${DIASPORA_C:-}" ] && [ -f "$HERE/env/workload.sh" ]; then
    # shellcheck disable=SC1091
    source "$HERE/env/workload.sh"
fi
: "${DIASPORA_C:?set DIASPORA_C to your diaspora-c install prefix (dir with include/diaspora/diaspora_c.h)}"
[ -f "$DIASPORA_C/include/diaspora/diaspora_c.h" ] || {
    echo "build.sh: no include/diaspora/diaspora_c.h under DIASPORA_C=$DIASPORA_C"; exit 1; }

SRC="$DARSHAN/darshan-runtime"
if [ "${DARSHAN_MPI:-0}" = "1" ]; then
    # MPI-aware build. The compiler MUST actually be able to link MPI and be
    # GCC-compatible (darshan's configure.ac:41 AX_PROG_CC_MPI + configure.ac:82
    # --with-gcc guard). Two hazards this handles:
    #   1. env/common.sh:19 EXPORTS CC=gcc, so a `${CC:-mpicc}` fallback never fires
    #      -- plain gcc reached configure, AX_PROG_CC_MPI silently disabled MPI, and
    #      the resulting "install-mpi" lib had ZERO PMPI wrappers / no MPIIO module
    #      (proven: nm -D | grep PMPI_ = 0; real MPI runs got bogus nprocs=1 rank=0
    #      per-process logs, no rank=-1 reduction). So we FORCE the compiler here,
    #      overriding any inherited CC, rather than using a no-op ${CC:-...} default.
    #   2. On Polaris the right MPI+GCC compiler is the craype `cc`/`CC` wrappers
    #      (they link cray-mpich's libmpi_gnu_123 and report __GNUC__); `mpicc` in a
    #      bare login shell is the PrgEnv-nvidia wrapper (fails --with-gcc). On LCRC
    #      the openmpi mpicc/mpicxx are correct.
    if [ "${ENV_PROFILE:-}" = "polaris" ]; then
        CC="${DARSHAN_MPI_CC:-cc}"
        CXX="${DARSHAN_MPI_CXX:-CC}"
    else
        CC="${DARSHAN_MPI_CC:-$(command -v mpicc)}"
        CXX="${DARSHAN_MPI_CXX:-$(command -v mpicxx || command -v mpic++)}"
    fi
    PREFIX="${PREFIX:-$DARSHAN/install-mpi}"
    BUILD="$DARSHAN/_build-mpi"
    # --with-mpi makes configure HARD-ERROR if MPI can't be enabled, instead of the
    # old silent non-MPI fallback that produced a broken "MPI" lib (configure.ac:43-45).
    MPI_FLAG="--with-mpi"
    echo "=== WITH-MPI build (profile=${ENV_PROFILE:-?}): CC=$CC CXX=$CXX prefix=$PREFIX ==="
else
    CC="${CC:-$(command -v gcc || command -v cc)}"
    CXX="${CXX:-$(command -v g++ || command -v c++)}"
    PREFIX="${PREFIX:-$DARSHAN/install}"
    BUILD="$DARSHAN/_build"
    MPI_FLAG="--without-mpi"
fi

# --- ensure the build tree belongs to THIS srcdir ----------------------------
# config.status records the srcdir it was configured with; a stale/foreign one
# (copied machine, moved path) makes `make` chase files that don't exist. Wipe
# unless the caller asked to keep a matching tree.
if [ -f "$BUILD/config.status" ]; then
    cfg_srcdir="$("$BUILD/config.status" --config 2>/dev/null \
                    | tr ' ' '\n' | sed -n "s/^'\?--srcdir=//p" | tr -d \"\' | head -1)"
    if [ "${DARSHAN_INCREMENTAL:-0}" = "1" ] && [ "$cfg_srcdir" = "$SRC" ]; then
        echo "=== reusing _build (DARSHAN_INCREMENTAL=1) ==="
    else
        echo "=== wiping stale _build (was: ${cfg_srcdir:-unknown}) ==="; rm -rf "$BUILD"
    fi
fi
mkdir -p "$BUILD" "$PREFIX"

# bootstrap autotools only if the generated configure is missing. darshan-runtime
# is its own autotools package (no prepare.sh of its own; the repo-root prepare.sh
# is just `autoreconf -fi`), so bootstrap it directly here.
[ -f "$SRC/configure" ] || ( cd "$SRC" && autoreconf -fi )

# defeat maintainer-mode regeneration: bump generated files >= their sources so
# `make` doesn't try to re-run aclocal/automake (dies if the local automake
# version differs from the one that produced the committed output).
if [ -f "$SRC/configure" ]; then
    touch "$SRC/aclocal.m4"                          2>/dev/null || true
    touch "$SRC/configure" "$SRC"/*.h.in             2>/dev/null || true
    find "$SRC" -name 'Makefile.in' -exec touch {} + 2>/dev/null || true
fi

JOBS="$( (command -v nproc >/dev/null 2>&1 && nproc) || echo 4)"

cd "$BUILD"
sh "$SRC/configure" \
    ${CC:+CC="$CC"} ${CXX:+CXX="$CXX"} \
    --prefix="$PREFIX" \
    --with-log-path-by-env=DARSHAN_LOGPATH \
    --with-jobid-env=PBS_JOBID \
    $MPI_FLAG \
    --with-diaspora-c="$DIASPORA_C" \
    DIASPORA_C_CFLAGS="-I$DIASPORA_C/include" \
    DIASPORA_C_LIBS="-L$DIASPORA_C/lib -ldiaspora-c -ldiaspora-stream-api -lstdc++" \
    PKG_CONFIG_PATH="$DIASPORA_C/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
make -j"$JOBS"
make install

# some libtool/install combos skip the unversioned dev symlink; LD_PRELOAD and
# the harness's darshan_lib() rely on it, so create it if missing.
if [ ! -e "$PREFIX/lib/libdarshan.so" ]; then
    so="$(ls "$PREFIX"/lib/libdarshan.so.* 2>/dev/null | sort | head -1)"
    [ -n "$so" ] && ln -sf "$(basename "$so")" "$PREFIX/lib/libdarshan.so"
fi

echo "=== built: $(ls "$PREFIX"/lib/libdarshan.so* 2>/dev/null | tr '\n' ' ')==="
echo "=== install prefix: $PREFIX ==="
echo "point the harness at it:  export DARSHAN_PREFIX=$PREFIX"
