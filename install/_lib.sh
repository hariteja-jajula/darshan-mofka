#!/bin/bash
# install/_lib.sh -- shared helpers for the install/*.sh phase scripts.
# Sourced, not executed. Provides: repo-root detection, config.yaml reader
# (no hardcoded paths), and say/die logging.
set -uo pipefail

# repo root = parent of the install/ dir this file lives in (works from anywhere).
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$INSTALL_DIR/.." && pwd)"
CONFIG="$INSTALL_DIR/config.yaml"

say() { printf '\n[install] %s\n' "$*"; }
die() { printf '\n[install] FATAL: %s\n' "$*" >&2; exit 1; }

confirm_install() {
    local item="$1" details="${2:-}"
    if [[ "${INSTALL_ASSUME_YES:-}" == 1 || "${INSTALL_ASSUME_YES:-}" == yes ]]; then
        say "$item missing; INSTALL_ASSUME_YES set, continuing"
        return 0
    fi
    [[ -n "$details" ]] && say "$item missing: $details" || say "$item missing"
    if [[ ! -t 0 ]]; then
        die "$item missing; rerun interactively or set INSTALL_ASSUME_YES=1 to allow install/setup"
    fi
    local ans
    read -r -p "Install/setup $item now? [y/N] " ans
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) die "$item not installed; stopping before dependency build" ;;
    esac
}

have_python_311() {
    local c
    for c in "${PY:-}" python3.14 python3.13 python3.12 python3.11 python3 python; do
        [[ -n "$c" ]] && command -v "$c" >/dev/null 2>&1 || continue
        "$c" -c 'import sys; sys.exit(0 if sys.version_info[:2] >= (3, 11) else 1)' 2>/dev/null \
            && { command -v "$c"; return 0; }
    done
    return 1
}

# spack_external_prefixes -- print the external `prefix:` paths declared in
# server/spack/spack.yaml, one per line. This is the SINGLE source of truth for
# Polaris system externals (mpich, libfabric, rdma, gcc, ...); do NOT hardcode
# these paths anywhere else. If Polaris bumps a version, edit spack.yaml only.
spack_external_prefixes() {
    local yaml="$REPO_ROOT/$(cfg spack.env_spec)"
    [[ -f "$yaml" ]] || return 0
    "${PY:-python3}" - "$yaml" <<'PY'
import sys, re
try:
    import yaml
    data = yaml.safe_load(open(sys.argv[1]))
    pkgs = (data.get("spack", {}) or {}).get("packages", {}) or {}
    seen = set()
    for _name, spec in pkgs.items():
        if not isinstance(spec, dict):
            continue
        for ext in spec.get("externals", []) or []:
            p = ext.get("prefix")
            if p and p not in seen:
                seen.add(p)
                print(p)
except Exception:
    # regex fallback: grab every `prefix: <path>` under packages/externals
    for line in open(sys.argv[1]):
        m = re.match(r'\s*prefix:\s*(\S+)', line)
        if m:
            print(m.group(1).strip().strip('"').strip("'"))
PY
}

# cfg <dotted.key> -- read a scalar from config.yaml (the shared reader lives in
# lib/config.sh; here we just bind it to this installer's $CONFIG).
# shellcheck disable=SC1091
source "$REPO_ROOT/lib/config.sh"
cfg() { cfg_get "$CONFIG" "$1"; }

# absolute path for a layout.* name (relative to repo root, which is on eagle)
layout_path() { printf '%s/%s\n' "$REPO_ROOT" "$(cfg "layout.$1")"; }

# require we're on a login node (has internet) for fetch phase
require_login_node() {
    if [[ -n "${PBS_JOBID:-}" ]]; then
        die "run this on a LOGIN node (compute nodes have no internet for downloads)"
    fi
}
