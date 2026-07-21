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

# cfg <dotted.key> -- read a scalar from config.yaml. Uses python (always present
# via the spack view or system) so we need no yaml CLI dependency.
cfg() {
    local key="$1"
    "${PY:-python3}" - "$CONFIG" "$key" <<'PY'
import sys
try:
    import yaml
    with open(sys.argv[1]) as f:
        data = yaml.safe_load(f)
    cur = data
    for part in sys.argv[2].split('.'):
        cur = cur[part]
    print(cur)
except ImportError:
    # minimal fallback parser (nested key: value) if pyyaml isn't importable yet
    import re
    want = sys.argv[2].split('.')
    depth_keys, out = [], None
    with open(sys.argv[1]) as f:
        for line in f:
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            indent = len(line) - len(line.lstrip())
            m = re.match(r'\s*([\w_]+):\s*(.*)', line)
            if not m:
                continue
            k, v = m.group(1), m.group(2).strip().strip('"').strip("'")
            level = indent // 2
            depth_keys = depth_keys[:level] + [k]
            if depth_keys == want and v:
                out = v
                break
    print(out if out is not None else "")
PY
}

# absolute path for a layout.* name (relative to repo root, which is on eagle)
layout_path() { printf '%s/%s\n' "$REPO_ROOT" "$(cfg "layout.$1")"; }

# require we're on a login node (has internet) for fetch phase
require_login_node() {
    if [[ -n "${PBS_JOBID:-}" ]]; then
        die "run this on a LOGIN node (compute nodes have no internet for downloads)"
    fi
}
