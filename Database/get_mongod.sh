#!/bin/bash
# Download a standalone MongoDB server (mongod) into Database/_mongo_env.
#
# FlowCept stores the streamed Darshan events in MongoDB, so you need a mongod
# binary. If your system already has one (module, conda, or on PATH) you can skip
# this and just point MONGOD at it. This script is the easy fallback: it grabs the
# official MongoDB tarball and unpacks it here, no admin rights needed.
#
# Usage:
#   bash Database/get_mongod.sh            # downloads the default version below
#   MONGO_VERSION=7.0.14 bash Database/get_mongod.sh
#
# After it runs, mongod is at Database/_mongo_env/bin/mongod and the env scripts
# pick it up automatically.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HERE/_mongo_env"
VERSION="${MONGO_VERSION:-7.0.14}"
# RHEL8 build works on LCRC/Improv and Polaris. Override MONGO_TARBALL if needed.
TARBALL="${MONGO_TARBALL:-mongodb-linux-x86_64-rhel8-${VERSION}.tgz}"
URL="https://fastdl.mongodb.org/linux/${TARBALL}"

if [[ -x "$DEST/bin/mongod" ]]; then
    echo "mongod already present: $DEST/bin/mongod"
    "$DEST/bin/mongod" --version | head -1
    exit 0
fi

mkdir -p "$DEST"
echo "downloading $URL"
tmp="$(mktemp -d)"
curl -fSL "$URL" -o "$tmp/mongo.tgz" || { echo "download failed: $URL"; exit 1; }
tar -xzf "$tmp/mongo.tgz" -C "$tmp"
# the tarball unpacks into a versioned dir; copy its bin/ contents into _mongo_env
src="$(find "$tmp" -maxdepth 1 -type d -name 'mongodb-linux-*' | head -1)"
[[ -n "$src" ]] || { echo "unexpected tarball layout"; exit 1; }
cp -r "$src/bin" "$DEST/"
rm -rf "$tmp"

echo "installed: $DEST/bin/mongod"
"$DEST/bin/mongod" --version | head -1
