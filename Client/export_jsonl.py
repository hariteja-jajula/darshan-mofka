#!/usr/bin/env python3

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
            # FlowCept stores some fields (e.g. ended_at) as native datetimes,
            # which json cannot encode; default=str renders them as ISO strings.
            out.write(json.dumps(doc, separators=(",", ":"), default=str) + "\n")
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
