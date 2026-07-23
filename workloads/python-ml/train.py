#!/usr/bin/env python3
"""A small machine-learning style workload that does real file I/O.

The point of this program is not the model. It is the I/O: it writes a dataset to
disk, reads it back over several epochs, and saves a checkpoint. That read/write
pattern is what the Darshan connector captures and streams to Mofka.

It uses PyTorch if it is installed, and falls back to NumPy if it is not, so it
runs on Python builds that have no PyTorch wheel. Either way the file I/O is the
same.

Usage:
    python train.py [data_dir]     # default data_dir: /tmp/mofka-ml
"""
import os
import sys
import struct

DATA_DIR = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mofka-ml"
N_FILES = int(os.environ.get("ML_FILES", "6"))
N_ROWS = int(os.environ.get("ML_ROWS", "512"))
N_COLS = int(os.environ.get("ML_COLS", "16"))
EPOCHS = int(os.environ.get("ML_EPOCHS", "2"))

os.makedirs(DATA_DIR, exist_ok=True)


def write_dataset():
    """Write N_FILES shards of random float32 rows as raw binary (POSIX I/O)."""
    import random
    paths = []
    for i in range(N_FILES):
        p = os.path.join(DATA_DIR, f"shard_{i}.bin")
        with open(p, "wb") as f:
            for _ in range(N_ROWS):
                row = [random.random() for _ in range(N_COLS)]
                f.write(struct.pack(f"{N_COLS}f", *row))
        paths.append(p)
    # a small text manifest too, so STDIO is exercised alongside POSIX
    with open(os.path.join(DATA_DIR, "manifest.txt"), "w") as f:
        f.write(f"files={N_FILES} rows={N_ROWS} cols={N_COLS}\n")
        for p in paths:
            f.write(p + "\n")
    return paths


def read_shard(path):
    """Read one shard back into a flat list of floats."""
    with open(path, "rb") as f:
        blob = f.read()
    n = len(blob) // 4
    return struct.unpack(f"{n}f", blob)


def main():
    paths = write_dataset()
    print(f"wrote {len(paths)} shards to {DATA_DIR}")

    try:
        import torch
        backend = f"torch {torch.__version__}"
    except Exception:
        torch = None
        backend = "numpy fallback"
    print(f"training backend: {backend}")

    # "training": read every shard each epoch and reduce it (real reads each epoch)
    total = 0.0
    for epoch in range(EPOCHS):
        epoch_sum = 0.0
        for p in paths:
            data = read_shard(p)
            if torch is not None:
                t = torch.tensor(data)
                epoch_sum += float(t.mean())
            else:
                epoch_sum += sum(data) / len(data)
        total += epoch_sum
        print(f"epoch {epoch}: mean-of-means={epoch_sum/len(paths):.6f}")

    # save a checkpoint (write path)
    ckpt = os.path.join(DATA_DIR, "checkpoint.bin")
    with open(ckpt, "wb") as f:
        f.write(struct.pack("d", total))
    print(f"saved checkpoint {ckpt}")
    print("python-ml workload complete")


if __name__ == "__main__":
    main()
