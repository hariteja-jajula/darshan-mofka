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
import resource


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


def regloop(iters):
    """Register-bound scalar FP recurrence: NO array/memory access (a handful of
    locals only). If streaming slows THIS as much as the memory-bound matmul, the
    cause is FREQUENCY (whole-core clock drop). If this stays flat while matmul
    slows, the cause is the MEMORY subsystem (cache/TLB/bandwidth/THP)."""
    x = 1.0000001
    y = 0.9999999
    acc = 0.0
    for _ in range(iters):
        x = x * 1.0000001 + 1e-9
        y = y * 0.9999999 + 1e-9
        acc += x - y
    return acc


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
    # register-bound diagnostic loop iterations per iter (0=off). Sized to ~1 matmul's
    # inner work so reg_s and matmul_s are comparable. Used to split frequency vs memory.
    reg_iters = env_long("REG_ITERS", 0)
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
    rchecksum = 0.0
    if compute > 0:
        mcells = matn * matn
        mA = [((i * 1103515245 + 12345) & 0xffff) / 65536.0 for i in range(mcells)]
        mB = [((i * 22695477 + 1) & 0xffff) / 65536.0 for i in range(mcells)]
        mC = [0.0] * mcells

    total_w = 0
    total_r = 0
    # CPU-time probe: distinguishes "app descheduled by a busy background thread"
    # (wall grows, self CPU flat) from "each matmul got more expensive: memory/cache
    # contention" (self CPU grows too). RUSAGE_SELF = whole process (all threads);
    # RUSAGE_THREAD = just this app thread (the interpreter loop).
    ru0_self = resource.getrusage(resource.RUSAGE_SELF)
    try:
        ru0_thr = resource.getrusage(resource.RUSAGE_THREAD)
    except (AttributeError, ValueError):
        ru0_thr = None
    # SPLIT TIMERS: separate the I/O region (where Darshan intercepts + the connector
    # runs) from the pure-compute matmul region (no I/O, no Darshan). If streaming's cost
    # is inline connector work -> io_s grows. If it's cache/bandwidth contention from
    # background streaming threads -> matmul_s grows (pure compute slowed).
    io_s = 0.0
    matmul_s = 0.0
    reg_s = 0.0
    t0 = time.monotonic()
    print("WORK_START_NS %d" % now_ns())
    sys.stdout.flush()

    for it in range(iters):
        path = os.path.join(dir_, "iter_%d.dat" % it)

        _tio = time.monotonic()
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
        io_s += time.monotonic() - _tio

        if compute > 0:
            _tm = time.monotonic()
            mchecksum += matmul_reps(mA, mB, mC, matn, compute)
            matmul_s += time.monotonic() - _tm
        # register-bound counterpart: same wall budget order, NO memory access.
        # REG_ITERS>0 enables it; sized to be comparable to one matmul.
        if reg_iters > 0:
            _tr = time.monotonic()
            rchecksum += regloop(reg_iters)
            reg_s += time.monotonic() - _tr

        if busy:
            busy_ms(sleep_ms)
        elif sleep_ms > 0:
            time.sleep(sleep_ms / 1000.0)

    print("WORK_END_NS %d" % now_ns())
    print("SPLIT io_s=%.2f matmul_s=%.2f reg_s=%.2f" % (io_s, matmul_s, reg_s))
    # CPU-time deltas over the WORK region (see probe above).
    ru1_self = resource.getrusage(resource.RUSAGE_SELF)
    cpu_self = (ru1_self.ru_utime - ru0_self.ru_utime) + (ru1_self.ru_stime - ru0_self.ru_stime)
    if ru0_thr is not None:
        ru1_thr = resource.getrusage(resource.RUSAGE_THREAD)
        cpu_thr = (ru1_thr.ru_utime - ru0_thr.ru_utime) + (ru1_thr.ru_stime - ru0_thr.ru_stime)
    else:
        cpu_thr = -1.0
    _wall = time.monotonic() - t0
    # CPU_PROBE wall=<s> cpu_self=<s,all threads> cpu_thread=<s,app thread only>
    #   cpu_thread/wall ~1.0  -> app thread ran flat out (matmul not slowed) -> wall growth = descheduling
    #   cpu_thread/wall  <1.0 -> app thread was starved of CPU (background thread stole the core)
    #   cpu_self >> cpu_thread -> a background (progress/rpc/drain) thread burned CPU
    print("CPU_PROBE wall=%.2f cpu_self=%.2f cpu_thread=%.2f" % (_wall, cpu_self, cpu_thr))
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
