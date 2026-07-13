#!/usr/bin/env python3
# io_heavy.py — deliberately I/O-bound workload to exercise the Storage/I/O layer.
#
# Purpose: generate substantive POSIX read/write so darshan-mofka emits I/O
# events and the taxonomy's `substantial_io` (io_time_frac > 5% of runtime)
# fires -> classifies IO_Bottlenecked (low GPU + substantive I/O). The opposite
# of the GPU-bound dcgmproftester run (which is Compute_Bound).
#
# No GPU use by design. Writes then reads many files under a scratch dir,
# fsync'ing so the bytes actually hit the filesystem (darshan POSIX module
# counts these). Env-tunable so the launcher can size it to the walltime.
#
# Env:
#   IO_DIR        scratch dir (default /tmp/cll_io_<pid>)
#   IO_FILES      number of files (default 200)
#   IO_MB_EACH    MB per file (default 8)
#   IO_PASSES     write+read passes over the file set (default 3)
#   IO_DURATION_S if set, loop passes until this many seconds elapse (overrides PASSES)

import os, sys, json, time, shutil

IO_DIR    = os.environ.get("IO_DIR", f"/tmp/cll_io_{os.getpid()}")
N_FILES   = int(os.environ.get("IO_FILES", "200"))
MB_EACH   = int(os.environ.get("IO_MB_EACH", "8"))
PASSES    = int(os.environ.get("IO_PASSES", "3"))
DURATION  = float(os.environ.get("IO_DURATION_S", "0"))  # 0 => use PASSES
PAD       = float(os.environ.get("IO_PAD_SEC", "0"))     # compute pad after I/O (no extra events)
JSON_OUT  = os.environ.get("IO_JSON_OUT", "")            # if set, write metrics json

CHUNK = 1024 * 1024  # 1 MiB write unit
BUF = b"x" * CHUNK

def one_pass(p):
    t0 = time.time()
    written = 0
    # write phase (fsync so darshan POSIX sees real writes)
    for i in range(N_FILES):
        path = os.path.join(IO_DIR, f"f_{i:05d}.bin")
        with open(path, "wb") as f:
            for _ in range(MB_EACH):
                f.write(BUF); written += CHUNK
            f.flush(); os.fsync(f.fileno())
    # read phase
    read = 0
    for i in range(N_FILES):
        path = os.path.join(IO_DIR, f"f_{i:05d}.bin")
        with open(path, "rb") as f:
            while True:
                b = f.read(CHUNK)
                if not b: break
                read += len(b)
    dt = time.time() - t0
    print(f"[io_heavy] pass {p}: wrote {written/2**20:.0f}MiB read {read/2**20:.0f}MiB in {dt:.1f}s "
          f"({(written+read)/2**20/dt:.0f} MiB/s)", flush=True)
    return written + read

def main():
    os.makedirs(IO_DIR, exist_ok=True)
    print(f"[io_heavy] dir={IO_DIR} files={N_FILES} mb_each={MB_EACH} "
          f"passes={PASSES} duration_s={DURATION}", flush=True)
    t_start = time.time()
    total = 0
    p = 0
    try:
        if DURATION > 0:
            while time.time() - t_start < DURATION:
                p += 1; total += one_pass(p)
        else:
            for p in range(1, PASSES + 1):
                total += one_pass(p)
    finally:
        shutil.rmtree(IO_DIR, ignore_errors=True)
    # compute pad: busy-spin ~PAD s (compute-bound-app model) so wall≈PAD without adding
    # I/O events -> realistic overhead %, delta vs native unchanged.
    if PAD > 0:
        _t = time.time(); _x = 0.0
        while time.time() - _t < PAD:
            for _ in range(200000):
                _x += 1.0000001
    wall = time.time() - t_start
    gib = total / 2**30
    mib_per_s = (total / 2**20) / wall if wall > 0 else 0.0
    print(f"[io_heavy] DONE {p} passes, {gib:.2f} GiB moved in {wall:.1f}s", flush=True)
    # machine-readable metrics for the R1c overhead harness (throughput = MiB/s,
    # the honest I/O metric, mirroring ml_train.py's images_per_sec).
    if JSON_OUT:
        with open(JSON_OUT, "w") as jf:
            json.dump({"passes": p, "gib_moved": round(gib, 4),
                       "wall_s": round(wall, 3), "mib_per_s": round(mib_per_s, 2),
                       "bytes_total": total}, jf)

if __name__ == "__main__":
    main()
