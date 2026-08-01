#!/usr/bin/env python3
"""
io_bench.py -- Python twin of workloads/c/io_bench.c. Same tunable POSIX I/O
benchmark for the Darshan -> Mofka stream, so we can compare connector overhead
for a C producer vs a Python producer at matching configs.

Each iteration writes a fresh file (IO_SIZE_MB in IO_BLOCK_KB chunks), fsync/close,
then reopens and reads it all back; a small IO_SLEEP_MS pause between iterations
makes it a *sustained stream* rather than a burst. Does POSIX I/O only via the raw
os.open/os.write/os.read syscalls (NOT buffered Python file objects) so Darshan's
POSIX module fires the same open/write/read/close records as the C version.

Knobs (env vars, same names/defaults as io_bench.c):
  IO_SIZE_MB   total MiB per iteration        (default 16)
  IO_ITERS     number of iterations           (default 16)
  IO_SLEEP_MS  sleep between iterations, ms    (default 50)
  IO_BLOCK_KB  write/read block size, KiB     (default 1024)
  COMPUTE_MODE sleep = sleep between iters (default); busy = CPU spin IO_SLEEP_MS
  COMPUTE      dense NxN matrix multiplies per iteration (default 0 = off)
  MATRIX_SIZE  matrix dimension N for COMPUTE                (default 256)

COMPUTE uses a pure-Python triple-loop matmul (apples-to-apples with the C triple
loop, no numpy dep) so it does REAL per-rank CPU work between I/O bursts. Note: the
Python triple loop is far slower than C, so match by RUNTIME (pick COMPUTE/MATRIX
to hit the target wall), not by identical knob values across languages.

Prints WORK_START_NS/WORK_END_NS (monotonic ns) around the I/O loop so the
overhead-study driver reads a self-timed WORK duration, not job wall time.

Run: python3 workloads/python-ml/io_bench.py [scratch_dir]
argv[1] = scratch dir for the I/O files (created if needed).
"""
import os
import sys
import time


def env_long(k, fallback):
    v = os.environ.get(k)
    if v is None or v == "":
        return fallback
    try:
        return int(v)
    except ValueError:
        return fallback


def now_ns():
    # monotonic ns -- the self-timed WORK clock the study parses.
    # time.monotonic_ns() is 3.7+; fall back to monotonic()*1e9 for 3.6.
    f = getattr(time, "monotonic_ns", None)
    if f is not None:
        return f()
    return int(time.monotonic() * 1_000_000_000)


def busy_ms(ms):
    # burn CPU for ms milliseconds (busy compute), vs sleep which yields
    if ms <= 0:
        return
    end = now_ns() + ms * 1_000_000
    spin = 0
    while now_ns() < end:
        spin += 1


def matmul_reps(A, B, C, n, reps):
    """`reps` dense NxN multiplies C=A*B (naive triple loop, one core). A/B/C are
    caller-owned flat lists filled once; perturb A each rep so it isn't hoisted and
    return a checksum so C isn't optimized away. Mirrors io_bench.c:matmul_reps."""
    total = 0.0
    for r in range(reps):
        A[r % (n * n)] += 1e-9                       # defeat hoisting
        for i in range(n):
            in_off = i * n
            for j in range(n):
                acc = 0.0
                for k in range(n):
                    acc += A[in_off + k] * B[k * n + j]
                C[in_off + j] = acc
        total += C[(r % n) * n + (r % n)]            # defeat DCE
    return total


def main():
    dir_ = sys.argv[1] if len(sys.argv) > 1 else "/tmp/dm-iobench-py"

    size_mb = env_long("IO_SIZE_MB", 16)
    iters = env_long("IO_ITERS", 16)
    sleep_ms = env_long("IO_SLEEP_MS", 50)
    block_kb = env_long("IO_BLOCK_KB", 1024)
    cm = os.environ.get("COMPUTE_MODE", "")
    busy = len(cm) > 0 and cm[0] in ("b", "B")       # busy vs sleep (default)
    compute = env_long("COMPUTE", 0)                 # NxN multiplies per iter; 0=off
    matn = env_long("MATRIX_SIZE", 256)              # matrix dimension N
    if size_mb < 1:
        size_mb = 1
    if iters < 1:
        iters = 1
    if sleep_ms < 0:
        sleep_ms = 0
    if block_kb < 1:
        block_kb = 1
    if compute < 0:
        compute = 0
    if matn < 1:
        matn = 1

    block = block_kb * 1024
    target = size_mb * 1024 * 1024
    nblocks = target // block                        # whole blocks per iter
    if nblocks < 1:
        nblocks = 1
    iter_bytes = nblocks * block

    print("io_bench_py: size_mb=%d iters=%d sleep_ms=%d block_kb=%d compute=%s "
          "matmul=%d matrix_size=%d (~%d MiB write + read per iter)"
          % (size_mb, iters, sleep_ms, block_kb, "busy" if busy else "sleep",
             compute, matn, iter_bytes // (1024 * 1024)))

    os.makedirs(dir_, exist_ok=True)

    buf = b"x" * block                               # fill once, reuse

    # Matmul buffers: allocate + seed ONCE (only when COMPUTE>0), reuse every iter.
    mA = mB = mC = None
    mchecksum = 0.0
    if compute > 0:
        mcells = matn * matn
        mA = [((i * 1103515245 + 12345) & 0xffff) / 65536.0 for i in range(mcells)]
        mB = [((i * 22695477 + 1) & 0xffff) / 65536.0 for i in range(mcells)]
        mC = [0.0] * mcells

    total_w = 0
    total_r = 0
    t0 = time.monotonic()
    print("WORK_START_NS %d" % now_ns())
    sys.stdout.flush()

    for it in range(iters):
        path = os.path.join(dir_, "iter_%d.dat" % it)

        fd = os.open(path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o644)
        for _ in range(nblocks):
            n = os.write(fd, buf)
            if n != block:
                raise IOError("short write")
            total_w += block
        os.fsync(fd)
        os.close(fd)

        fd = os.open(path, os.O_RDONLY)
        while True:
            chunk = os.read(fd, block)
            if not chunk:
                break
            total_r += len(chunk)
        os.close(fd)

        if compute > 0:
            mchecksum += matmul_reps(mA, mB, mC, matn, compute)

        if busy:
            busy_ms(sleep_ms)
        elif sleep_ms > 0:
            time.sleep(sleep_ms / 1000.0)

    print("WORK_END_NS %d" % now_ns())
    sys.stdout.flush()

    # clean up scratch files so we don't fill /tmp
    for it in range(iters):
        path = os.path.join(dir_, "iter_%d.dat" % it)
        try:
            os.unlink(path)
        except OSError:
            pass

    elapsed = time.monotonic() - t0
    print("io_bench_py done: wrote=%d bytes read=%d bytes iters=%d matmul=%d "
          "matrix_size=%d checksum=%.6e elapsed=%.2fs"
          % (total_w, total_r, iters, compute, matn, mchecksum, elapsed))


if __name__ == "__main__":
    main()
