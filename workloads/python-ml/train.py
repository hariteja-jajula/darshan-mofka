#!/usr/bin/env python3
"""Realistic NumPy MLP training workload with genuine file I/O.

Unlike a toy that only reads shards back and takes a mean, this trains a REAL
2-layer MLP with mini-batch SGD and backpropagation on a
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

# --- heavy profiling gate (ML_PROFILE=1) -------------------------------------
# When OFF, this module behaves byte-for-byte like the plain trainer (matters:
# an already-running job re-execs this file each rep). When ON, we add a
# stdlib-only heavy profiler: per-region wall + per-THREAD CPU (time.thread_time)
# and RUSAGE_THREAD/RUSAGE_SELF deltas (minor-faults, ctx-switches, utime/stime).
# No external tool, no extra module loads in the app -- safe in this venv.
PROFILE = os.environ.get("ML_PROFILE", "0") == "1"
if PROFILE:
    # Pin BLAS/OMP to a fixed thread count BEFORE importing numpy so the app
    # thread is the SOLE compute thread. python-ml (unlike io_bench) is not
    # capped by the harness, so a multithreaded BLAS helper would make
    # RUSAGE_SELF (whole-process CPU) diverge from the app thread and mask the
    # connector's real per-core cost. Must be set pre-import to take effect.
    _bt = os.environ.get("ML_BLAS_THREADS", "1")
    for _v in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS",
               "NUMEXPR_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "BLIS_NUM_THREADS"):
        os.environ[_v] = _bt
    import resource

import numpy as np

# Per-region accumulators: name -> [wall_ns, thread_cpu_ns]. Filled only when
# PROFILE; _region() is a no-op-cheap call otherwise (never invoked).
_prof = {"write": [0, 0], "read": [0, 0], "compute": [0, 0]}


def _region(name, wall_ns, cpu_ns):
    r = _prof[name]
    r[0] += wall_ns
    r[1] += cpu_ns

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
    """Read one shard back from disk and split into features / label.

    When PROFILE, charge the disk read to the 'read' region (wall + thread CPU)
    so we can separate connector-inflated I/O time from compute time. The op
    itself is identical either way.
    """
    if PROFILE:
        w0 = time.monotonic_ns(); c0 = time.thread_time_ns()
        a = np.load(path)
        _region("read", time.monotonic_ns() - w0, time.thread_time_ns() - c0)
    else:
        a = np.load(path)                            # real read each epoch
    return a[:, :-1], a[:, -1:]


def main():
    rng = np.random.default_rng(SEED)

    # WORK markers bracket the self-timed work (dataset write + train loop) so the
    # overhead-study driver reads a monotonic WORK duration, not job wall time.
    # Heavy-profile snapshots: whole-window per-thread + per-process rusage so we
    # can attribute the streaming overhead to CPU character, not just wall time.
    if PROFILE:
        _rt0 = resource.getrusage(resource.RUSAGE_THREAD)
        _rs0 = resource.getrusage(resource.RUSAGE_SELF)
        _tc0 = time.thread_time_ns()          # app-thread CPU (user+sys)
        _pc0 = time.process_time_ns()         # whole-process CPU (all threads)
        _w0 = time.monotonic_ns()
    print(f"WORK_START_NS {_mono_ns()}", flush=True)

    if PROFILE:
        _ww0 = time.monotonic_ns(); _wc0 = time.thread_time_ns()
        paths = write_dataset(rng)
        _region("write", time.monotonic_ns() - _ww0, time.thread_time_ns() - _wc0)
    else:
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
            if PROFILE:
                _cw0 = time.monotonic_ns(); _cc0 = time.thread_time_ns()
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
            if PROFILE:
                _region("compute", time.monotonic_ns() - _cw0, time.thread_time_ns() - _cc0)
        if (epoch + 1) % ckpt_every == 0 and saved < N_CKPT:
            cp = os.path.join(DATA_DIR, f"checkpoint_{saved}.npz")
            if PROFILE:
                _kw0 = time.monotonic_ns(); _kc0 = time.thread_time_ns()
                np.savez(cp, W1=W1, b1=b1, W2=W2, b2=b2)
                _region("write", time.monotonic_ns() - _kw0, time.thread_time_ns() - _kc0)
            else:
                np.savez(cp, W1=W1, b1=b1, W2=W2, b2=b2)  # real multi-KB checkpoint
            saved += 1
        if epoch % max(1, EPOCHS // 10) == 0 or epoch == EPOCHS - 1:
            print(f"epoch {epoch}: loss={loss_sum / max(1, n_batches):.6f}", flush=True)

    print(f"WORK_END_NS {_mono_ns()}", flush=True)

    if PROFILE:
        # Whole-window deltas: wall, app-thread CPU, whole-process CPU, and the
        # kernel counters that discriminate the overhead mechanism.
        wall_s = (time.monotonic_ns() - _w0) / 1e9
        tcpu_s = (time.thread_time_ns() - _tc0) / 1e9      # app thread only
        pcpu_s = (time.process_time_ns() - _pc0) / 1e9     # all threads (this proc)
        rt1 = resource.getrusage(resource.RUSAGE_THREAD)
        rs1 = resource.getrusage(resource.RUSAGE_SELF)
        t_utime = rt1.ru_utime - _rt0.ru_utime
        t_stime = rt1.ru_stime - _rt0.ru_stime
        t_minflt = rt1.ru_minflt - _rt0.ru_minflt          # app-thread minor faults
        t_nivcsw = rt1.ru_nivcsw - _rt0.ru_nivcsw          # involuntary ctx-sw (preempt)
        t_nvcsw = rt1.ru_nvcsw - _rt0.ru_nvcsw             # voluntary ctx-sw (blocking)
        s_minflt = rs1.ru_minflt - _rs0.ru_minflt          # whole-proc minor faults
        s_utime = rs1.ru_utime - _rs0.ru_utime
        s_stime = rs1.ru_stime - _rs0.ru_stime
        # Region split (wall + app-thread CPU), the decisive io-vs-compute test.
        for _rn in ("write", "read", "compute"):
            _rw, _rc = _prof[_rn]
            print(f"MLPROF region={_rn} wall_s={_rw/1e9:.3f} cpu_s={_rc/1e9:.3f}", flush=True)
        # CPU_PROBE-style line: ratio pcpu/tcpu ~1.0 => no sidecar core peg on this proc.
        print(f"MLPROF window wall_s={wall_s:.3f} thread_cpu_s={tcpu_s:.3f} "
              f"proc_cpu_s={pcpu_s:.3f} cpu_ratio={pcpu_s/max(tcpu_s,1e-9):.3f}", flush=True)
        # The mechanism discriminators. instructions-vs-cycles needs perf, but
        # these already separate the top hypotheses:
        #   thread stime up      => more kernel time on app thread (syscalls/contention)
        #   thread minflt up     => more page faults => allocator churn/mem pressure
        #   thread nivcsw up     => app thread PREEMPTED more => scheduler contention
        #   thread nvcsw up      => app thread BLOCKS more (voluntary) => lock/wait
        #   proc minflt >> thread=> faults on OTHER threads (drain/progress) not app
        print(f"MLPROF thread utime_s={t_utime:.3f} stime_s={t_stime:.3f} "
              f"minflt={t_minflt} nivcsw={t_nivcsw} nvcsw={t_nvcsw}", flush=True)
        print(f"MLPROF proc utime_s={s_utime:.3f} stime_s={s_stime:.3f} "
              f"minflt={s_minflt}", flush=True)

    print(f"saved {saved} checkpoints to {DATA_DIR}", flush=True)
    print("python-ml workload complete", flush=True)


if __name__ == "__main__":
    main()
