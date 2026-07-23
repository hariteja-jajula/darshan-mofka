#!/bin/bash
# check-deps.sh -- read-only dependency check for the darshan-mofka demo.
#
# Tells you, at a glance, what you already have vs. what's still missing, so you
# can SKIP any setup you don't need. It downloads and builds NOTHING; it only
# probes. Run it from the repo root:
#
#   bash check-deps.sh            # human summary; exit 0 if everything is ready
#   bash check-deps.sh --quiet    # only print MISSING rows
#
# Intended for Darshan devs on Polaris who already have most of the stack. If a
# row is MISSING, the top-level README's "Dependencies & Environments" section
# says how to get it (or run the automated backup: bash install/setup.sh).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

QUIET=0; [[ "${1:-}" == "--quiet" ]] && QUIET=1
MISSING=0

# Source the project env (best effort) so we probe the SAME tools the demo uses.
# env.sh resolves the profile (arg > $DARSHAN_MOFKA_PROFILE > config.yaml > host).
# shellcheck disable=SC1091
source "$HERE/server/env.sh" >/dev/null 2>&1 || true
PROFILE="${DARSHAN_MOFKA_PROFILE:-polaris}"; ENV_ARG="--$PROFILE"

row() { # row <PRESENT|MISSING|WARN> <label> <detail>
    local st="$1" label="$2" detail="${3:-}"
    [[ "$st" != PRESENT ]] && MISSING=1
    if [[ "$QUIET" == 1 && "$st" == PRESENT ]]; then return; fi
    printf '  %-7s %-22s %s\n' "$st" "$label" "$detail"
}

echo "== darshan-mofka dependency check (nothing is downloaded; profile=$PROFILE) =="

# --- submodules ---------------------------------------------------------------
if [[ -e "$HERE/darshan/darshan-runtime/configure.ac" && -e "$HERE/diaspora-stream-api/CMakeLists.txt" ]]; then
    row PRESENT "submodules" "darshan + diaspora-stream-api checked out"
else
    row MISSING "submodules" "run: git submodule update --init --recursive"
fi

# --- compiler -----------------------------------------------------------------
if command -v cc >/dev/null 2>&1; then
    row PRESENT "compiler (cc)" "$(command -v cc)"
else
    row MISSING "compiler (cc)" "load a compiler/MPI PrgEnv (Polaris: PrgEnv-gnu)"
fi

# --- spack externals (declared in server/spack/spack.yaml) --------------------
if [[ "$PROFILE" == polaris && -f "$HERE/install/_lib.sh" ]]; then
    # shellcheck disable=SC1091
    source "$HERE/install/_lib.sh" >/dev/null 2>&1
    ext_miss=()
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        [[ -e "$p" ]] || ext_miss+=("$p")
    done < <(spack_external_prefixes)
    if ((${#ext_miss[@]})); then
        row MISSING "spack externals" "missing: ${ext_miss[*]}"
    else
        row PRESENT "spack externals" "all prefixes from spack.yaml present"
    fi
else
    row PRESENT "spack externals" "not required for profile=$PROFILE"
fi

# --- spack view (native stack: bedrock/mochi/mofka/darshan) -------------------
if [[ -n "${MOFKA_SPACK_VIEW:-}" && -d "$MOFKA_SPACK_VIEW" ]] && command -v bedrock >/dev/null 2>&1; then
    row PRESENT "spack view" "$MOFKA_SPACK_VIEW (bedrock on PATH)"
elif [[ -n "${MOFKA_SPACK_VIEW:-}" && -d "$MOFKA_SPACK_VIEW" ]]; then
    row WARN    "spack view" "$MOFKA_SPACK_VIEW exists but 'bedrock' not on PATH"
else
    row MISSING "spack view" "build server/spack/spack.yaml, export MOFKA_SPACK_VIEW"
fi

# --- python venv (>= 3.11) ----------------------------------------------------
if [[ -n "${PY:-}" ]] && "$PY" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3,11) else 1)' 2>/dev/null; then
    row PRESENT "python (>=3.11)" "$("$PY" -V 2>&1) [$PY]"
else
    row MISSING "python (>=3.11)" "create venv from server/requirements.txt"
fi

# --- flowcept consumer importable --------------------------------------------
if [[ -n "${PY:-}" ]] && "$PY" -c 'import pymongo, flowcept' >/dev/null 2>&1; then
    row PRESENT "flowcept consumer" "pymongo + flowcept import OK"
else
    row MISSING "flowcept consumer" "pip install -r server/requirements.txt && pip install -e flowcept/"
fi

# --- mongod -------------------------------------------------------------------
if [[ -n "${MONGOD:-}" && -x "${MONGOD:-}" ]]; then
    row PRESENT "mongod" "$MONGOD"
elif command -v mongod >/dev/null 2>&1; then
    row PRESENT "mongod" "$(command -v mongod)"
else
    row MISSING "mongod" "install MongoDB server tarball/conda, set MONGOD (see README)"
fi

# --- darshan build (the Mofka connector library) ------------------------------
DLIB="${DARSHAN_PREFIX:-$HERE/darshan/install}/lib/libdarshan.so"
if [[ -e "$DLIB" ]]; then
    row PRESENT "darshan build" "$DLIB"
else
    row MISSING "darshan build" "run: ./build.sh  (needs DIASPORA_C set)"
fi

echo
if [[ "$MISSING" == 0 ]]; then
    echo "All dependencies present -- you can skip setup and run:  bash job.sh"
    exit 0
else
    echo "Some dependencies are MISSING (see rows above)."
    echo "Fix them per the README 'Dependencies & Environments' section,"
    echo "or run the automated backup:  bash install/setup.sh"
    exit 1
fi
