#!/bin/bash
# Run io_test under darshan, streaming every POSIX event to the mofka server.
#
#   ./run.sh                 # uses the server started by internship/server/start-server.sh
#
# Watch the events arrive with, in another shell:
#   cd ../server && source env.sh && ./consume mofka.json darshan 60
set -e
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

source "$ROOT/server/env.sh"

LIB="$(darshan_lib)"
[ -n "$LIB" ] || { echo "no libdarshan under $DARSHAN_PREFIX/lib -- build it: $ROOT/server/build-darshan.sh"; exit 1; }
GROUP="$ROOT/server/mofka.json"
[ -f "$GROUP" ] || { echo "no mofka.json -- start the server first: $ROOT/server/start-server.sh"; exit 1; }

"${CC:-cc}" "$HERE/io_test.c" -o "$HERE/io_test"

export DARSHAN_MOFKA_ENABLE=1
export DARSHAN_MOFKA_GROUP_FILE="$GROUP"
export DARSHAN_MOFKA_TOPIC=darshan
export DARSHAN_MOFKA_ENABLE_POSIX=1
export DARSHAN_MOFKA_VERBOSE=1
export DARSHAN_ENABLE_NONMPI=1

darshan_ensure_logdir >/dev/null   # pre-create the dated darshan-log dir (no warning)

echo "=== running io_test under darshan -> mofka ==="
LD_PRELOAD="$LIB" "$HERE/io_test" "${IO_TEST_DIR:-/tmp}"
