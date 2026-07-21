#!/bin/bash
# job.sh -- one-shot end-to-end smoke test of the README pipeline (non-MPI).
#
# Run on a Polaris COMPUTE node from the repo root:
#     qsub -I -q debug -A <project> -l select=1 -l walltime=01:00:00 -l filesystems=home:eagle
#     cd <repo root on eagle>
#     bash job.sh
#
# It follows README sections 1-12 for the POSIX/STDIO smoke workload:
#   env + pkg-config fix -> build darshan (non-MPI) + util + workload ->
#   fresh broker -> mongod + FlowCept consumer -> run workload ->
#   flush + export MongoDB -> JSONL -> verify -> reconstruct + compare to native.
#
# mongod: resolved automatically (env.sh finds it on eagle). Override with
#   MONGOD=/path/to/mongod bash job.sh
# Skip the (slow) rebuild if already built:
#   SKIP_BUILD=1 bash job.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$ROOT"
SKIP_BUILD="${SKIP_BUILD:-0}"

say()  { printf '\n########## %s ##########\n' "$*"; }
die()  { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. environment (README section 1) + Polaris pkg-config fix (sections 2/3)
# ---------------------------------------------------------------------------
say "1. environment"
export TERM="${TERM:-xterm}"
# shellcheck disable=SC1091
source server/env.sh --polaris || die "could not source server/env.sh --polaris"
module unload darshan 2>/dev/null || true
export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH#/soft/perftools/darshan/darshan-3.4.4/lib/pkgconfig:}"
export DARSHAN_LOGPATH="${DARSHAN_LOGPATH:-$ROOT/darshan-logs}"
darshan_ensure_logdir >/dev/null
export DARSHAN_PREFIX="$ROOT/darshan/install"
echo "ROOT=$ROOT"
echo "MOFKA_SPACK_VIEW=$MOFKA_SPACK_VIEW"
echo "DIASPORA_C=$DIASPORA_C"
echo "CC=$CC"; echo "PY=$PY"
echo "MONGOD=${MONGOD:-<unresolved>}"
pkg-config --exists zlib && echo "zlib OK" || echo "WARN: zlib not visible to pkg-config"

# ---------------------------------------------------------------------------
# 1b. PROVENANCE CHECKS -- fail if we'd use something from OUTSIDE the project.
# Guards against strays: ~/.local python, /usr/bin/python, a $HOME conda mongod,
# a system spack view, etc. Everything must resolve under the repo, the project's
# spack/venv, or eagle (the shared FS this project lives on).
# ---------------------------------------------------------------------------
say "1b. provenance checks (no stray tools from outside the project)"
PROJECT_ROOT="$(cd "$ROOT/.." && pwd)"          # e.g. /eagle/<proj>/<user>/test
# allowed roots: the repo, its parent tree (spack view/venv/mongo on eagle)
_allowed() {  # _allowed <label> <path> <allowed-substr-1> [more...]
    local label="$1" path="$2"; shift 2
    [[ -n "$path" ]] || die "$label is empty/unresolved"
    local ok=0 pat
    for pat in "$@"; do [[ "$path" == *"$pat"* ]] && ok=1; done
    if [[ "$ok" = "1" ]]; then
        echo "  OK   $label -> $path"
    else
        die "$label resolves OUTSIDE the project: $path
       (expected under one of: $*)
       Fix your environment (source server/env.sh --polaris in a clean shell)."
    fi
}
# hard failures on known strays
case "$PY" in
    *"/.local/"*|/usr/bin/python*|/bin/python*)
        die "PY is a stray interpreter: $PY (expected the project venv or spack view)";;
esac
[[ "$(command -v cmake)" == *"$PROJECT_ROOT"* || "$(command -v cmake)" == *"/spack/"* ]] \
    || die "cmake is not from the spack view: $(command -v cmake)"

_allowed "PY (python)"        "$PY"               "$PROJECT_ROOT" "$ROOT"
_allowed "MOFKA_SPACK_VIEW"   "$MOFKA_SPACK_VIEW" "$PROJECT_ROOT" "/spack/"
_allowed "DIASPORA_C"         "$DIASPORA_C"       "$ROOT"
_allowed "DARSHAN_PREFIX"     "$DARSHAN_PREFIX"   "$ROOT"
_allowed "cmake"              "$(command -v cmake)" "$PROJECT_ROOT" "/spack/"
[[ -n "${MONGOD:-}" ]] && _allowed "MONGOD" "$MONGOD" "$PROJECT_ROOT" "$ROOT"
echo "  provenance OK: all tools resolve inside the project/eagle"

# ---------------------------------------------------------------------------
# 2. build darshan (non-MPI) + darshan-util + workload  (README sections 2-3)
# ---------------------------------------------------------------------------
if [[ "$SKIP_BUILD" = "1" && -e "$(darshan_lib 2>/dev/null)" ]]; then
    say "2. build (SKIP_BUILD=1, using existing $(darshan_lib))"
else
    say "2a. build diaspora-stream-api (if needed)"
    if [[ -e "diaspora-stream-api/install/include/diaspora/diaspora_c.h" ]]; then
        echo "already installed -> skip"
    else
        ( cd diaspora-stream-api \
          && cmake -S . -B _build -DENABLE_C_API=ON -DENABLE_PYTHON=ON \
                -DCMAKE_PREFIX_PATH="$MOFKA_SPACK_VIEW" \
                -DCMAKE_INSTALL_PREFIX="$PWD/install" \
          && cmake --build _build -j && cmake --install _build ) || die "diaspora build failed"
        # shellcheck disable=SC1091
        source server/env.sh --polaris
        module unload darshan 2>/dev/null || true
        export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:${PKG_CONFIG_PATH#/soft/perftools/darshan/darshan-3.4.4/lib/pkgconfig:}"
    fi

    say "2b. build darshan runtime (non-MPI)"
    ./build.sh || die "darshan build failed"
    echo "darshan_lib=$(darshan_lib)"
    [[ -e "$(darshan_lib)" ]] || die "libdarshan.so missing after build"

    say "2c. build darshan-util (parser + reconstruct)"
    ( cd darshan/darshan-util
      if [[ ! -f _build_util/Makefile ]]; then
          ( cd .. && ./prepare.sh )
          mkdir -p _build_util
          ( cd _build_util && ../configure --prefix="$PWD/../install" )
      fi
      ( cd _build_util && make -j4 && make install ) ) || die "darshan-util build failed"

    say "2d. build smoke workload"
    "$CC" -O2 workloads/c/mofka_forward_smoke.c -o workloads/c/mofka_forward_smoke \
        || die "workload compile failed"
fi

B="$ROOT/darshan/darshan-util/install/bin"
[[ -x "$B/darshan-parser" && -x "$B/darshan-mofka-reconstruct" ]] \
    || die "darshan-util tools missing at $B (run without SKIP_BUILD)"

# ---- provenance: the built lib + its linked libs must come from the project ---
say "2e. provenance: darshan lib + linked libs"
LIB="$(darshan_lib)"
[[ "$LIB" == "$ROOT"/* ]] || die "darshan_lib is not in the repo: $LIB"
echo "  OK   darshan_lib -> $LIB"
# the runtime lib links diaspora-c + (transitively) mofka/mochi from the view;
# make sure none resolve to a system/$HOME location.
if command -v ldd >/dev/null 2>&1; then
    # allowed: the repo, the spack view/stack, the project tree on eagle, system.
    # Canonicalize the view path: MOFKA_SPACK_VIEW may contain '..' (e.g. test/..)
    # while ldd reports the resolved real path -- compare on real paths.
    _view_real="$(readlink -f "$MOFKA_SPACK_VIEW" 2>/dev/null || echo "$MOFKA_SPACK_VIEW")"
    _spackroot_real="$(readlink -f "$PROJECT_ROOT/.." 2>/dev/null || echo "$PROJECT_ROOT")"
    BAD=""
    while IFS= read -r solib; do
        [[ -z "$solib" ]] && continue
        real="$(readlink -f "$solib" 2>/dev/null || echo "$solib")"
        case "$real" in
            "$ROOT"/*|"$_spackroot_real"/*|"$_view_real"/*|\
            /lib/*|/lib64/*|/usr/lib/*|/opt/cray/*|/soft/*) ;;   # allowed
            *) BAD+="$solib"$'\n' ;;
        esac
    done < <(ldd "$LIB" 2>/dev/null | awk '/=>/{print $3}')
    if [[ -n "$BAD" ]]; then
        echo "  WARN: some linked libs resolve outside project/system dirs:"
        echo "$BAD" | sed 's/^/    /'
    else
        echo "  OK   linked libs resolve inside project/eagle or system dirs"
    fi
fi

# ---------------------------------------------------------------------------
# 3. resolve mongod (README section 6; env.sh already tried)
# ---------------------------------------------------------------------------
say "3. mongod"
MONGOD="${MONGOD:-$(command -v mongod || true)}"
[[ -x "$MONGOD" ]] || die "mongod not found on eagle; see README section 6 (must live on eagle, fetched on a login node)"
echo "MONGOD=$MONGOD"; "$MONGOD" --version | head -1

# ---------------------------------------------------------------------------
# 4. fresh broker (README section 4)
# ---------------------------------------------------------------------------
say "4. fresh Mofka broker"
pkill -f capture.py 2>/dev/null || true
bash server/stop-server.sh >/dev/null 2>&1 || true
sleep 2
bash server/start-server.sh || die "start-server.sh failed"
GROUP="$ROOT/server/mofka.json"
[[ -s "$GROUP" ]] || die "no mofka.json after start-server.sh"
trap 'bash server/stop-server.sh >/dev/null 2>&1 || true' EXIT

# ---------------------------------------------------------------------------
# 5-6. output files + FlowCept consumer (README sections 5-6)
# ---------------------------------------------------------------------------
say "5. FlowCept consumer"
RUN_DIR="$ROOT/server/_flowcept_run"
MONGO_DB=darshan_stream; MONGO_PORT=27017
EVENTS_JSONL="/tmp/darshan-mofka-events.jsonl"
# fresh run dir each time: capture_flowcept.sh keeps mongo_data here; a stale one
# makes the NEXT run re-count leftover docs (seen: 13 sends but 26 exported).
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR"
RUN_DIR="$RUN_DIR" MONGO_DB="$MONGO_DB" MONGO_PORT="$MONGO_PORT" MONGOD="$MONGOD" \
MOFKA_GROUP="$GROUP" \
bash server/capture_flowcept.sh > "$RUN_DIR/flowcept_capture.out" 2>&1 &
FC=$!
until grep -q 'consumer alive' "$RUN_DIR/flowcept_capture.out"; do
    kill -0 "$FC" 2>/dev/null || { cat "$RUN_DIR/flowcept_capture.out"; die "consumer failed to start"; }
    sleep 1
done
echo "consumer alive (pid $FC)"

# ---------------------------------------------------------------------------
# 7. run the smoke workload (README section 7)
# ---------------------------------------------------------------------------
say "7. run smoke workload"
env \
  DARSHAN_ENABLE_NONMPI=1 DARSHAN_MOFKA_ENABLE=1 \
  DARSHAN_MOFKA_GROUP_FILE="$GROUP" DARSHAN_MOFKA_TOPIC=darshan \
  DARSHAN_MOFKA_TIMING=1 DARSHAN_MOFKA_BATCH=0 DARSHAN_MOFKA_MAX_BATCHES=64 \
  DARSHAN_LOGPATH="$DARSHAN_LOGPATH" LD_PRELOAD="$(darshan_lib)" \
  ./workloads/c/mofka_forward_smoke /tmp/mofka-forward-smoke \
  > /tmp/darshan-mofka-workload.out 2> /tmp/darshan-mofka-workload.err
cat /tmp/darshan-mofka-workload.out
SENDS="$(grep -c 'darshan-mofka\[timing\] send' /tmp/darshan-mofka-workload.err || true)"
echo "sends: $SENDS"
[[ "$SENDS" -gt 0 ]] || echo "WARN: 0 sends"

# ---------------------------------------------------------------------------
# 8. flush + export mongo -> JSONL (README section 8)
# ---------------------------------------------------------------------------
say "8. flush + export"
touch "$RUN_DIR/SHUTDOWN"
until grep -q 'Export now' "$RUN_DIR/flowcept_capture.out"; do
    kill -0 "$FC" 2>/dev/null || { tail -40 "$RUN_DIR/flowcept_capture.out"; die "consumer died before export"; }
    sleep 1
done
"$PY" server/export_jsonl.py 127.0.0.1 "$MONGO_DB" --mongo-port "$MONGO_PORT" \
    > "$EVENTS_JSONL" 2> "$RUN_DIR/export.count"
kill "$FC" 2>/dev/null || true; wait "$FC" 2>/dev/null || true
cat "$RUN_DIR/export.count" || true
echo "exported lines: $(wc -l < "$EVENTS_JSONL")"
grep -E 'INGEST:|tasks total=' "$RUN_DIR/flowcept_capture.out" || true

# ---------------------------------------------------------------------------
# 9. verify (README section 9)
# ---------------------------------------------------------------------------
say "9. verify events"
"$PY" - "$EVENTS_JSONL" <<'PY'
import json, sys
from collections import Counter
mods, ops = Counter(), Counter()
for line in open(sys.argv[1]):
    ev = json.loads(line); mods[ev.get('module')] += 1; ops[ev.get('op')] += 1
print("modules:", dict(mods)); print("ops:", dict(ops))
PY
echo "--- STDIO close events (the validated fix) ---"
grep -E '"module":"STDIO".*"op":"close"' "$EVENTS_JSONL" | head || echo "(none)"

# ---------------------------------------------------------------------------
# 11. reconstruct + compare to native (README section 11)
# ---------------------------------------------------------------------------
say "11. reconstruct + compare to native"
rm -f /tmp/job_partial.darshan
"$B/darshan-mofka-reconstruct" "$EVENTS_JSONL" /tmp/job_partial.darshan
NATIVE="$(find "$DARSHAN_LOGPATH" -name "*mofka_forward_smoke*.darshan" -newermt "-15 min" 2>/dev/null | head -1)"
echo "native: ${NATIVE:-<none found>}"
"$B/darshan-parser" --show-incomplete /tmp/job_partial.darshan | grep -E "^(POSIX|STDIO)" | sort > /tmp/r.txt
echo "=== reconstructed OPENS ==="; grep OPENS /tmp/r.txt
if [[ -n "$NATIVE" ]]; then
    "$B/darshan-parser" --show-incomplete "$NATIVE" | grep -E "^(POSIX|STDIO)" | sort > /tmp/n.txt
    echo "=== native OPENS ==="; grep OPENS /tmp/n.txt
fi

say "DONE"
echo "events: $EVENTS_JSONL   reconstructed: /tmp/job_partial.darshan"
