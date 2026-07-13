#!/usr/bin/env python3
# io_ckpt.py -- ML-style checkpointing workload for the darshan->mofka overhead
# study. Runs EPOCHS of light "compute" and every CKPT_EVERY epochs writes (and
# reads back) a model checkpoint. Bursty periodic I/O -- the realistic training
# signature: long compute stretches punctuated by large sequential write spikes.
#
# Pure stdlib, no GPU. Run under LD_PRELOAD=libdarshan.so so its POSIX I/O streams
# to mofka. Adapted from crosslayer_live/workloads/checkpoint_heavy.py.
#
# Env:
#   CKPT_DIR         scratch dir           (default /tmp/io_ckpt_<pid>)
#   EPOCHS           total epochs          (default 320)
#   CKPT_EVERY       checkpoint cadence    (default 32  -> 10 checkpoints)
#   CKPT_SIZE_MB     MB per checkpoint     (default 64)
#   EPOCH_COMPUTE_S  light compute/epoch s (default 0.05)
import os, time, shutil

CKPT_DIR = os.environ.get("CKPT_DIR", "/tmp/io_ckpt_%d" % os.getpid())
EPOCHS   = int(os.environ.get("EPOCHS", "320"))
EVERY    = int(os.environ.get("CKPT_EVERY", "32"))
SIZE_MB  = int(os.environ.get("CKPT_SIZE_MB", "64"))
COMPUTE  = float(os.environ.get("EPOCH_COMPUTE_S", "0.05"))

CHUNK = 1024 * 1024
BUF   = b"x" * CHUNK

def compute(sec):
    # light CPU so an "epoch" reads as compute, not pure sleep
    t0 = time.time(); a = 0.0; i = 0
    while time.time() - t0 < sec:
        for _ in range(20000):
            a += (i * 1.000001) ** 0.5; i += 1
    return a

def checkpoint(idx):
    p = os.path.join(CKPT_DIR, "ckpt_%05d.bin" % idx)
    with open(p, "wb") as f:                 # write burst
        for _ in range(SIZE_MB):
            f.write(BUF)
        f.flush(); os.fsync(f.fileno())
    with open(p, "rb") as f:                 # read back (resume-style load)
        while f.read(CHUNK):
            pass

def main():
    os.makedirs(CKPT_DIR, exist_ok=True)
    print("[io_ckpt] epochs=%d ckpt_every=%d size_mb=%d dir=%s"
          % (EPOCHS, EVERY, SIZE_MB, CKPT_DIR), flush=True)
    t0 = time.time(); n = 0
    try:
        for e in range(1, EPOCHS + 1):
            compute(COMPUTE)
            if e % EVERY == 0:
                checkpoint(e); n += 1
                print("[io_ckpt] epoch %d: checkpoint %d written" % (e, n), flush=True)
    finally:
        shutil.rmtree(CKPT_DIR, ignore_errors=True)
    print("[io_ckpt] done: %d epochs, %d checkpoints, %.1fs"
          % (EPOCHS, n, time.time() - t0), flush=True)

if __name__ == "__main__":
    main()
