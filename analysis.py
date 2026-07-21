#!/usr/bin/env python3
"""analysis.py -- verify the MPIIO validation run produced by job.sh.

Temporary/scratch: run right after `bash job.sh`, from the repo root:
    python3 analysis.py

Reads the artifacts job.sh left under _mpiio_validation/ and prints a verdict on
whether MPIIO events (especially close) reached the stream and the reconstructed
log. Copy the whole output back for review.
"""
import json
import os
import subprocess
import sys
from collections import Counter

OUT = os.environ.get("MPIIO_OUT") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "_mpiio_validation"
)
EVENTS = os.path.join(OUT, "events.jsonl")
RECON = os.path.join(OUT, "job_partial.darshan")


def hdr(msg):
    print("\n" + "=" * 8 + " " + msg + " " + "=" * 8)


def fail(msg):
    print("MISSING: " + msg)


# ---------------------------------------------------------------------------
# 1. exported JSONL: module/op breakdown
# ---------------------------------------------------------------------------
hdr("1. exported events (%s)" % EVENTS)
mpiio_close = 0
mod_op = Counter()
mods = Counter()
if not os.path.exists(EVENTS):
    fail("events.jsonl not found -- did job.sh finish step 7?")
else:
    n = 0
    for line in open(EVENTS):
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        n += 1
        m = ev.get("module")
        o = ev.get("op")
        mods[m] += 1
        mod_op[(m, o)] += 1
        if m == "MPIIO" and o == "close":
            mpiio_close += 1
    print("total events:", n)
    print("modules:", dict(mods))
    print("(module, op) counts:")
    for k, v in sorted(mod_op.items(), key=lambda x: (str(x[0][0]), str(x[0][1]))):
        print("   ", k, v)

# ---------------------------------------------------------------------------
# 2. reconstructed darshan log: MPIIO records via darshan-parser
# ---------------------------------------------------------------------------
hdr("2. reconstructed log (%s)" % RECON)
parser = None
bin_path_file = os.path.join(OUT, "util_bin_path")
if os.path.exists(bin_path_file):
    b = open(bin_path_file).read().strip()
    cand = os.path.join(b, "darshan-parser")
    if os.path.exists(cand):
        parser = cand
if parser is None:
    cand = os.path.join(
        os.path.dirname(os.path.abspath(__file__)),
        "darshan/darshan-util/install/bin/darshan-parser",
    )
    parser = cand if os.path.exists(cand) else None

if not os.path.exists(RECON):
    fail("job_partial.darshan not found -- did reconstruct run (step 8)?")
elif parser is None:
    fail("darshan-parser not found -- cannot inspect reconstructed log")
else:
    try:
        out = subprocess.run(
            [parser, "--show-incomplete", RECON],
            capture_output=True, text=True, timeout=120,
        ).stdout
    except Exception as e:  # noqa: BLE001
        out = ""
        print("parser error:", e)
    counters = Counter()
    files_by_mod = {}
    for ln in out.splitlines():
        if ln.startswith(("MPIIO", "POSIX", "STDIO")):
            parts = ln.split()
            if len(parts) >= 2:
                counters[parts[0]] += 1
        if "MPIIO_F_" in ln or "\tMPIIO_" in ln or ln.startswith("MPIIO"):
            pass
    print("record lines per module:", dict(counters))
    # surface any MPIIO close-ish counters explicitly
    mpiio_lines = [
        ln for ln in out.splitlines()
        if ln.startswith("MPIIO") and (
            "OPENS" in ln or "WRITES" in ln or "READS" in ln or "CLOSE" in ln
        )
    ]
    if mpiio_lines:
        print("MPIIO counter lines:")
        for ln in mpiio_lines[:40]:
            print("   ", ln)
    else:
        print("no MPIIO counter lines found in reconstructed log")

# ---------------------------------------------------------------------------
# 3. verdict
# ---------------------------------------------------------------------------
hdr("3. VERDICT")
mpiio_total = mods.get("MPIIO", 0)
print("MPIIO events in stream:", mpiio_total)
print("MPIIO 'close' events   :", mpiio_close)
if mpiio_total > 0 and mpiio_close > 0:
    print("RESULT: PASS -- MPIIO events including close reached the stream.")
    sys.exit(0)
elif mpiio_total > 0:
    print("RESULT: PARTIAL -- MPIIO present but NO close events (close-fix NOT confirmed).")
    sys.exit(1)
else:
    print("RESULT: FAIL -- no MPIIO events (lib may not be MPI-enabled; check job.sh step 3b).")
    sys.exit(2)
