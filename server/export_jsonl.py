#!/usr/bin/env python3
# export_jsonl.py -- dump FlowCept-ingested darshan events from MongoDB back out
# as the SAME JSONL the reconstructor (darshan-mofka-reconstruct) consumes.
#
# This is the bridge for "scale mode": FlowCept's DocumentInserter lands each
# streamed darshan event as a task doc in mongo (keeping all fields verbatim --
# module/record_id/rank/rec_size/rec_hex/seq/ended_at/... ). This tool queries
# those docs and writes one compact JSON object per line, so the offline
# reconstructor stays unchanged and DB-agnostic:
#
#     server/export_jsonl.py <mongo_host> <mongo_db> [--topic-schema darshan_runtime] \
#         | ./darshan/install/bin/darshan-mofka-reconstruct - job_partial.darshan
#
# Use --out only when you explicitly want JSONL for debugging.
#
# Only darshan task docs are exported (schema in {darshan_runtime,
# darshan_runtime_agg}); FlowCept's own workflow/bookkeeping docs are skipped.
# Docs are emitted in ascending `seq` order so the stream reads back in the order
# the producer pushed it (the reconstructor keeps the latest snapshot per
# (module,record_id,rank), so order only affects ties -- but stable order makes
# the JSONL diffable and reproducible).
#
# Requires pymongo (same interpreter that runs FlowCept).
import argparse
import json
import sys

from pymongo import MongoClient, ASCENDING

DARSHAN_SCHEMAS = ["darshan_runtime", "darshan_runtime_agg"]


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Export FlowCept-ingested darshan events from mongo as reconstructor JSONL")
    ap.add_argument("mongo_host")
    ap.add_argument("mongo_db")
    ap.add_argument("--mongo-port", type=int, default=27017)
    ap.add_argument("--collection", default="tasks",
                    help="FlowCept tasks collection (default: tasks)")
    ap.add_argument("--workflow-id", default=None,
                    help="restrict to one workflow_id (e.g. wf-<jobid>)")
    ap.add_argument("--out", default="-",
                    help="output path or '-' for stdout (default)")
    args = ap.parse_args()

    client = MongoClient(args.mongo_host, args.mongo_port,
                         serverSelectionTimeoutMS=10000)
    coll = client[args.mongo_db][args.collection]

    query = {"schema": {"$in": DARSHAN_SCHEMAS}}
    if args.workflow_id:
        query["workflow_id"] = args.workflow_id

    out = sys.stdout if args.out == "-" else open(args.out, "w")
    n = 0
    try:
        cursor = coll.find(query, {"_id": 0}).sort("seq", ASCENDING)
        for doc in cursor:
            out.write(json.dumps(doc, separators=(",", ":")) + "\n")
            n += 1
    finally:
        if out is not sys.stdout:
            out.close()

    # count to stderr so stdout stays pure JSONL (mirrors capture.py's contract)
    sys.stderr.write(f"exported {n} darshan docs from "
                     f"{args.mongo_db}.{args.collection}"
                     + (f" (workflow_id={args.workflow_id})" if args.workflow_id else "")
                     + "\n")
    return 0 if n > 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
