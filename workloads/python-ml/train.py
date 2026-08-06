#!/usr/bin/env python3
"""Realistic NumPy MLP training workload with genuine file I/O.

Unlike the old toy (train_old.py), which only read shards back and took a mean,
this trains a REAL 2-layer MLP with mini-batch SGD and backpropagation on a
synthetic regression dataset. The file-I/O pattern mirrors real ML training:

  * the dataset is written once as float32 .npy shards -- ONE buffered write per
    shard (np.save), the way any numpy/torch/TF pipeline actually writes data;
  * every shard is re-read from disk each epoch (np.load) and iterated in
    mini-batches -- the dominant, legitimate I/O of real training;
  * model checkpoints (all weight matrices) are written periodically with
    np.savez -- a realistic multi-KB checkpoint, not an 8-byte placeholder.

NumPy only: no PyTorch / TensorFlow needed (neither is installed in this venv).

Contract kept for the harness (lib/run.sh reads these):
  * data dir            = argv[1]   (a per-run scratch dir the harness supplies)
  * prints WORK_START_NS / WORK_END_NS (monotonic ns, flushed) around the work
  * honors ML_FILES, ML_ROWS, ML_COLS, ML_EPOCHS, ML_CHECKPOINTS
  * prints "python-ml workload complete" at the end

Usage:
    python train.py [data_dir]     # default data_dir: /tmp/mofka-ml
"""
import os
import sys
import time

import numpy as np

DATA_DIR = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mofka-ml"
N_FILES = int(os.environ.get("ML_FILES", "6"))
N_ROWS = int(os.environ.get("ML_ROWS", "512"))
N_COLS = int(os.environ.get("ML_COLS", "16"))
EPOCHS = int(os.environ.get("ML_EPOCHS", "2"))
N_CKPT = int(os.environ.get("ML_CHECKPOINTS", "1"))
# training hyper-params (sensible defaults; tunable but not required by the harness)
HIDDEN = int(os.environ.get("ML_HIDDEN", "128"))   # hidden units
BATCH = int(os.environ.get("ML_BATCH", "256"))     # mini-batch size
LR = float(os.environ.get("ML_LR", "0.01"))        # SGD learning rate
SEED = int(os.environ.get("ML_SEED", "0"))

os.makedirs(DATA_DIR, exist_ok=True)


def _mono_ns():
    """Monotonic nanoseconds; time.monotonic_ns() is 3.7+, fall back for 3.6."""
    f = getattr(time, "monotonic_ns", None)
    return f() if f else int(time.monotonic() * 1e9)


def write_dataset(rng):
    """Write N_FILES float32 shards of [features | label] rows.

    One buffered write per shard (np.save), like any real numpy pipeline. Labels
    come from a fixed random teacher (y = X . w_true + small noise) so the model
    can actually reduce its loss -- real gradients doing real work.
    """
    w_true = rng.standard_normal((N_COLS, 1)).astype(np.float32)
    paths = []
    for i in range(N_FILES):
        X = rng.standard_normal((N_ROWS, N_COLS)).astype(np.float32)
        y = X @ w_true + np.float32(0.01) * rng.standard_normal((N_ROWS, 1)).astype(np.float32)
        shard = np.concatenate([X, y], axis=1)      # last column is the label
        p = os.path.join(DATA_DIR, f"shard_{i}.npy")
        np.save(p, shard)                            # ONE buffered write per shard
        paths.append(p)
    # a small text manifest too, so STDIO is exercised alongside POSIX
    with open(os.path.join(DATA_DIR, "manifest.txt"), "w") as f:
        f.write(f"files={N_FILES} rows={N_ROWS} cols={N_COLS} hidden={HIDDEN} batch={BATCH}\n")
        for p in paths:
            f.write(p + "\n")
    return paths


def load_shard(path):
    """Read one shard back from disk and split into features / label."""
    a = np.load(path)                                # real read each epoch
    return a[:, :-1], a[:, -1:]


def main():
    rng = np.random.default_rng(SEED)

    # WORK markers bracket the self-timed work (dataset write + train loop) so the
    # overhead-study driver reads a monotonic WORK duration, not job wall time.
    print(f"WORK_START_NS {_mono_ns()}", flush=True)

    paths = write_dataset(rng)
    print(f"wrote {len(paths)} shards to {DATA_DIR} ({N_FILES}x{N_ROWS}x{N_COLS})", flush=True)
    print(f"training backend: numpy {np.__version__} (MLP {N_COLS}-{HIDDEN}-1, SGD)", flush=True)

    # 2-layer MLP: in(N_COLS) -> hidden(HIDDEN) ReLU -> out(1). He initialization.
    W1 = rng.standard_normal((N_COLS, HIDDEN)).astype(np.float32) * np.float32(np.sqrt(2.0 / N_COLS))
    b1 = np.zeros((1, HIDDEN), dtype=np.float32)
    W2 = rng.standard_normal((HIDDEN, 1)).astype(np.float32) * np.float32(np.sqrt(2.0 / HIDDEN))
    b2 = np.zeros((1, 1), dtype=np.float32)

    ckpt_every = max(1, EPOCHS // max(1, N_CKPT))
    saved = 0
    for epoch in range(EPOCHS):
        loss_sum = 0.0
        n_batches = 0
        for p in paths:
            X, y = load_shard(p)                     # re-read the shard from disk
            for s in range(0, X.shape[0], BATCH):
                xb = X[s:s + BATCH]
                yb = y[s:s + BATCH]
                # forward
                z1 = xb @ W1 + b1
                a1 = np.maximum(z1, 0.0)             # ReLU
                out = a1 @ W2 + b2
                diff = out - yb
                loss_sum += float(np.mean(diff * diff))
                n_batches += 1
                # backward (MSE loss)
                g = np.float32(2.0 / xb.shape[0]) * diff
                gW2 = a1.T @ g
                gb2 = g.sum(axis=0, keepdims=True)
                da1 = g @ W2.T
                dz1 = da1 * (z1 > 0)
                gW1 = xb.T @ dz1
                gb1 = dz1.sum(axis=0, keepdims=True)
                # SGD update
                W2 -= np.float32(LR) * gW2
                b2 -= np.float32(LR) * gb2
                W1 -= np.float32(LR) * gW1
                b1 -= np.float32(LR) * gb1
        if (epoch + 1) % ckpt_every == 0 and saved < N_CKPT:
            cp = os.path.join(DATA_DIR, f"checkpoint_{saved}.npz")
            np.savez(cp, W1=W1, b1=b1, W2=W2, b2=b2)  # real multi-KB checkpoint
            saved += 1
        if epoch % max(1, EPOCHS // 10) == 0 or epoch == EPOCHS - 1:
            print(f"epoch {epoch}: loss={loss_sum / max(1, n_batches):.6f}", flush=True)

    print(f"WORK_END_NS {_mono_ns()}", flush=True)
    print(f"saved {saved} checkpoints to {DATA_DIR}", flush=True)
    print("python-ml workload complete", flush=True)


if __name__ == "__main__":
    main()
