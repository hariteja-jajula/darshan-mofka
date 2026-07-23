#!/bin/bash
# lib/config.sh -- one YAML reader shared by job.sh, server/start_server.sh, the study
# scripts, and install/_lib.sh. Reads a single scalar by dotted key from a YAML file,
# with inline/full-line comment stripping. Uses PyYAML when available, else a small
# indent-based fallback (2-space nesting) so it works before the venv exists.
#
#   cfg_get <file> <dotted.key> [default]   -> prints the scalar (or default if missing)
#
# This is the generalized form of the original install/_lib.sh cfg(); that file now
# sources this and keeps a thin `cfg <key>` wrapper over $CONFIG for the installer.

cfg_get() {
    local file="$1" key="$2" default="${3:-}" val
    val="$("${PY:-python3}" - "$file" "$key" <<'PY'
import sys
path, key = sys.argv[1], sys.argv[2]
def strip(v):
    return v.split(' #', 1)[0].strip().strip('"').strip("'") if isinstance(v, str) else v
out = None
try:
    import yaml
    with open(path) as f:
        cur = yaml.safe_load(f)
    for part in key.split('.'):
        cur = cur[part]
    out = strip(cur)
except ImportError:
    import re
    want = key.split('.'); depth_keys = []
    with open(path) as f:
        for line in f:
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            indent = len(line) - len(line.lstrip())
            m = re.match(r'\s*([\w_]+):\s*(.*)', line)
            if not m:
                continue
            k, v = m.group(1), strip(m.group(2))
            depth_keys = depth_keys[:indent // 2] + [k]
            if depth_keys == want and v != "":
                out = v
                break
except (KeyError, TypeError, FileNotFoundError):
    out = None
print(out if out is not None else "")
PY
)"
    [ -n "$val" ] && printf '%s\n' "$val" || printf '%s\n' "$default"
}
