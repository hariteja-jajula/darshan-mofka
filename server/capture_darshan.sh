#!/usr/bin/env bash
# Capture a Mofka topic and write a reconstructed partial .darshan log.
set -euo pipefail

if [[ $# -lt 3 || $# -gt 5 ]]; then
    echo "Usage: $0 <groupfile> <topic> <output.darshan> [target_events] [idle_s]" >&2
    exit 1
fi

groupfile="$1"
topic="$2"
outfile="$3"
target="${4:-100000000}"
idle_s="${5:-20}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${ROOT:-$(cd "$script_dir/.." && pwd)}"
py="${PY:-python3}"
reconstruct="${DARSHAN_MOFKA_RECONSTRUCT:-$root/darshan/install/bin/darshan-mofka-reconstruct}"

[[ -x "$reconstruct" ]] || { echo "missing executable: $reconstruct" >&2; exit 1; }

"$py" "$script_dir/capture.py" "$groupfile" "$topic" "$target" "$idle_s" \
  | "$reconstruct" - "$outfile"
