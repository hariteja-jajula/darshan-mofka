#!/usr/bin/env python3
"""io_ml.py -- small ML-style I/O workload for the Darshan->Mofka overhead study.

Emulates the I/O pattern of an ML training step WITHOUT needing torch (which has no
py3.14 wheel here): generate a sharded dataset (many files), then "train" by
reading shards in epochs and writing periodic checkpoints. All real POSIX/STDIO
I/O, so the Darshan connector sees open/read/write/close events.

Run under LD_PRELOAD=libdarshan.so + DARSHAN_MOFKA_ENABLE=1 like the C workloads.

argv: workdir [nfiles] [file_kb] [epochs]
"""
import os
import sys

def main():
    workdir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/io_ml"
    nfiles = int(sys.argv[2]) if len(sys.argv) > 2 else 32
    file_kb = int(sys.argv[3]) if len(sys.argv) > 3 else 256
    epochs = int(sys.argv[4]) if len(sys.argv) > 4 else 2
    data = os.path.join(workdir, "data")
    ckpt = os.path.join(workdir, "ckpt")
    os.makedirs(data, exist_ok=True)
    os.makedirs(ckpt, exist_ok=True)
    chunk = b"x" * 1024

    # 1. generate sharded dataset (nfiles files, file_kb KiB each)
    for i in range(nfiles):
        p = os.path.join(data, f"shard_{i:04d}.bin")
        with open(p, "wb") as f:
            for _ in range(file_kb):
                f.write(chunk)

    # 2. "train": read every shard each epoch, checkpoint after each epoch
    total = 0
    for ep in range(epochs):
        for i in range(nfiles):
            p = os.path.join(data, f"shard_{i:04d}.bin")
            with open(p, "rb") as f:
                while True:
                    b = f.read(65536)
                    if not b:
                        break
                    total += len(b)
        with open(os.path.join(ckpt, f"epoch_{ep}.ckpt"), "wb") as f:
            f.write(b"CKPT" * 256)
            f.flush()
            os.fsync(f.fileno())

    # 3. cleanup dataset (keep the run self-contained on tmpfs)
    for i in range(nfiles):
        os.unlink(os.path.join(data, f"shard_{i:04d}.bin"))
    print(f"io_ml done: {nfiles} shards x {file_kb} KiB, {epochs} epochs, read {total} bytes")

if __name__ == "__main__":
    main()
