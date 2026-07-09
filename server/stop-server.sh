#!/bin/bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/env.sh"
cd "$HERE"
[ -f bedrock.pid ] && kill "$(cat bedrock.pid)" 2>/dev/null
rm -f bedrock.pid
echo "stopped."
