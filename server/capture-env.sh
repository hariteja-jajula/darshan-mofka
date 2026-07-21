#!/bin/bash
# capture-env.sh -- snapshot the ACTUAL Polaris environment this demo ran in, so
# it can be shipped/reproduced. Run it on a Polaris COMPUTE node AFTER a good run
# (env sourced, stack built):
#
#   source server/env.sh --polaris
#   bash server/capture-env.sh
#
# Writes human-readable + machine-readable snapshots under server/env-snapshot/.
# These are committed so a fresh account can see exactly what was in play.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/server/env-snapshot"
mkdir -p "$OUT"
say() { printf '[capture-env] %s\n' "$*"; }

# --- 1. loaded modules --------------------------------------------------------
say "modules -> modules.txt"
{ module list 2>&1 || true; } > "$OUT/modules.txt"

# --- 2. key environment variables the demo relies on --------------------------
say "demo env vars -> demo-env.txt"
{
    for v in MOFKA_SPACK_VIEW DIASPORA_C DARSHAN_PREFIX DARSHAN_LOGPATH \
             MOFKA_PROTOCOL BEDROCK_PROTOCOL PY CC CXX MONGOD \
             PYTHONPATH LD_LIBRARY_PATH PATH; do
        printf '%s=%s\n' "$v" "${!v:-}"
    done
} > "$OUT/demo-env.txt"

# --- 3. compiler / mpi / os ---------------------------------------------------
say "toolchain -> toolchain.txt"
{
    echo "## hostname"; hostname
    echo "## uname";    uname -a
    echo "## cc --version"; "${CC:-cc}" --version 2>&1 | head -3
    echo "## which cmake"; command -v cmake
    echo "## cmake --version"; cmake --version 2>&1 | head -1
    echo "## which bedrock"; command -v bedrock 2>&1
    echo "## which mongod / version"; echo "${MONGOD:-<unset>}"; "${MONGOD:-mongod}" --version 2>&1 | head -1
    echo "## python"; "${PY:-python3}" -VV
} > "$OUT/toolchain.txt"

# --- 4. spack: concretized specs of what the view provides --------------------
if command -v spack >/dev/null 2>&1; then
    say "spack find -> spack-find.txt (+ spack.lock already committed)"
    spack find -lvc 2>&1 > "$OUT/spack-find.txt" || true
else
    say "spack not on PATH; skipping spack-find (server/spack/spack.lock is the pinned spec)"
fi

# --- 5. python: exact frozen packages in the venv -----------------------------
say "pip freeze -> pip-freeze.txt"
"${PY:-python3}" -m pip freeze 2>/dev/null > "$OUT/pip-freeze.txt" || \
    echo "(pip freeze failed)" > "$OUT/pip-freeze.txt"

# --- 6. conda env export for mongo (if the mongo env exists) ------------------
_MONGO_ENV_DIR=""
[[ -n "${MONGOD:-}" ]] && _MONGO_ENV_DIR="$(dirname "$(dirname "$MONGOD")")"
if command -v conda >/dev/null 2>&1 && [[ -n "$_MONGO_ENV_DIR" && -d "$_MONGO_ENV_DIR/conda-meta" ]]; then
    say "conda env export (mongo) -> mongo-env.actual.yml"
    conda env export -p "$_MONGO_ENV_DIR" --no-builds 2>/dev/null > "$OUT/mongo-env.actual.yml" || true
else
    say "no conda mongo env introspectable; server/mongo-environment.yml is the spec"
fi

# --- 7. imports sanity (proves the python side is wired) ----------------------
say "python import check -> imports.txt"
"${PY:-python3}" - > "$OUT/imports.txt" 2>&1 <<'PY' || true
mods = ["pydiaspora_stream_api", "mochi.mofka.client", "pymongo", "flowcept"]
for m in mods:
    try:
        __import__(m); print(f"OK   {m}")
    except Exception as e:
        print(f"FAIL {m}: {e}")
PY

say "done. snapshot in: $OUT"
ls -la "$OUT"
