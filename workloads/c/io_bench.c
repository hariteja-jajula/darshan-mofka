/*
 * io_bench.c -- moderate, tunable POSIX I/O benchmark for the Darshan -> Mofka
 * stream. Each iteration writes a fresh file (IO_SIZE_MB in IO_BLOCK_KB chunks),
 * fsync/close, then reopens and reads it all back; a small IO_SLEEP_MS pause
 * between iterations makes it a *sustained stream* rather than a burst, so the
 * downstream drain keeps up. Does POSIX I/O only -- no Mofka calls; Darshan
 * (LD_PRELOAD=libdarshan.so) instruments it and the connector streams records.
 *
 * Knobs (env vars, with defaults for standalone use):
 *   IO_SIZE_MB   total MiB per iteration        (default 16)
 *   IO_ITERS     number of iterations           (default 16)
 *   IO_SLEEP_MS  sleep between iterations, ms    (default 50)
 *   IO_BLOCK_KB  write/read block size, KiB     (default 1024)
 *   COMPUTE_MODE sleep = usleep between iters (default); busy = CPU spin for the
 *                same nominal IO_SLEEP_MS (real compute for fixed-work calibration)
 *   COMPUTE      dense NxN matrix multiplies per iteration (default 0 = off)
 *   MATRIX_SIZE  matrix dimension N for COMPUTE                (default 256)
 * Defaults ~= 16 iters * 16 MiB * 2 (write+read) ~= 512 MiB total, moderate.
 *
 * COMPUTE adds real per-rank CPU work between I/O bursts (C=A*B triple loop, one
 * core/rank) so the stream can be studied under compute. Naive login-node timing:
 * ~0.06 s/multiply at N=256, ~0.55 s at N=512 -- per-rank compute ~= IO_ITERS *
 * COMPUTE * that. It does NOT change I/O counters, so strict_compare is unaffected.
 *
 * Prints WORK_START_NS/WORK_END_NS (CLOCK_MONOTONIC) around the I/O loop so the
 * overhead-study driver reads a self-timed WORK duration, not job wall time.
 *
 * Build: cc -O2 workloads/c/io_bench.c -o workloads/c/io_bench
 * argv[1] = scratch dir for the I/O files (created if needed).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>

static void die(const char* m) { perror(m); exit(1); }

/* return env var k as a long, else fallback */
static long env_long(const char* k, long fallback)
{
    const char* v = getenv(k);
    if (!v || !*v) return fallback;
    return atol(v);
}

static double now_sec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* monotonic nanoseconds -- the self-timed WORK clock the study parses */
static unsigned long long now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (unsigned long long)ts.tv_sec * 1000000000ULL + (unsigned long long)ts.tv_nsec;
}

/* burn CPU for ms milliseconds (busy compute), vs usleep which yields */
static void busy_ms(long ms)
{
    if (ms <= 0) return;
    unsigned long long end = now_ns() + (unsigned long long)ms * 1000000ULL;
    volatile unsigned long long spin = 0;
    while (now_ns() < end) spin++;
}

/* run `reps` dense NxN multiplies C=A*B (naive triple loop, one core). A/B/C are
 * caller-owned, filled once by the caller; we perturb A each rep so the compiler
 * can't hoist the loop, and return a checksum so C isn't dead-code-eliminated. */
static double matmul_reps(double* A, double* B, double* C, long n, long reps)
{
    double sum = 0.0;
    for (long r = 0; r < reps; r++) {
        A[r % (n * n)] += 1e-9;                         /* defeat hoisting */
        for (long i = 0; i < n; i++)
            for (long j = 0; j < n; j++) {
                double acc = 0.0;
                for (long k = 0; k < n; k++) acc += A[i * n + k] * B[k * n + j];
                C[i * n + j] = acc;
            }
        sum += C[(r % n) * n + (r % n)];                /* defeat DCE */
    }
    return sum;
}

int main(int argc, char** argv)
{
    const char* dir = (argc > 1) ? argv[1] : "/tmp/dm-iobench";

    long size_mb  = env_long("IO_SIZE_MB",  16);
    long iters    = env_long("IO_ITERS",    16);
    long sleep_ms = env_long("IO_SLEEP_MS", 50);
    long block_kb = env_long("IO_BLOCK_KB", 1024);
    const char* cm = getenv("COMPUTE_MODE");
    int busy = (cm && (cm[0] == 'b' || cm[0] == 'B'));  /* busy vs sleep (default) */
    long compute = env_long("COMPUTE",      0);         /* NxN multiplies per iter; 0=off */
    long matn    = env_long("MATRIX_SIZE",  256);       /* matrix dimension N */
    if (size_mb  < 1) size_mb  = 1;
    if (iters    < 1) iters    = 1;
    if (sleep_ms < 0) sleep_ms = 0;
    if (block_kb < 1) block_kb = 1;
    if (compute  < 0) compute  = 0;
    if (matn     < 1) matn     = 1;

    size_t block   = (size_t)block_kb * 1024;
    size_t target  = (size_t)size_mb  * 1024 * 1024;
    long   nblocks = (long)(target / block);            /* whole blocks per iter */
    if (nblocks < 1) nblocks = 1;
    size_t iter_bytes = (size_t)nblocks * block;

    printf("io_bench: size_mb=%ld iters=%ld sleep_ms=%ld block_kb=%ld compute=%s "
           "matmul=%ld matrix_size=%ld (~%ld MiB write + read per iter)\n",
           size_mb, iters, sleep_ms, block_kb, busy ? "busy" : "sleep",
           compute, matn, (long)(iter_bytes / (1024 * 1024)));

    if (mkdir(dir, 0755) != 0 && errno != EEXIST) die("mkdir");

    char* buf = malloc(block);
    if (!buf) die("malloc");
    memset(buf, 'x', block);                            /* fill once, reuse */

    /* Matmul buffers: allocate + seed ONCE (only when COMPUTE>0), reuse every iter. */
    double *mA = NULL, *mB = NULL, *mC = NULL, mchecksum = 0.0;
    if (compute > 0) {
        size_t mcells = (size_t)matn * (size_t)matn;
        mA = malloc(mcells * sizeof(double));
        mB = malloc(mcells * sizeof(double));
        mC = malloc(mcells * sizeof(double));
        if (!mA || !mB || !mC) die("malloc matmul");
        for (size_t i = 0; i < mcells; i++) {
            mA[i] = (double)(((long)i * 1103515245L + 12345L) & 0xffff) / 65536.0;
            mB[i] = (double)(((long)i * 22695477L   + 1L)     & 0xffff) / 65536.0;
        }
    }

    unsigned long long total_w = 0, total_r = 0;
    double t0 = now_sec();
    printf("WORK_START_NS %llu\n", now_ns());
    fflush(stdout);

    for (long it = 0; it < iters; it++) {
        char path[600];
        snprintf(path, sizeof path, "%s/iter_%ld.dat", dir, it);

        int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
        if (fd < 0) die("open write");
        for (long b = 0; b < nblocks; b++) {
            if (write(fd, buf, block) != (ssize_t)block) die("write");
            total_w += block;
        }
        if (fsync(fd) != 0) die("fsync");
        if (close(fd) != 0) die("close write");

        fd = open(path, O_RDONLY);
        if (fd < 0) die("open read");
        ssize_t n;
        while ((n = read(fd, buf, block)) > 0) total_r += (unsigned long long)n;
        if (n < 0) die("read");
        if (close(fd) != 0) die("close read");

        if (compute > 0) mchecksum += matmul_reps(mA, mB, mC, matn, compute);

        if (busy) busy_ms(sleep_ms);
        else if (sleep_ms > 0) usleep((useconds_t)(sleep_ms * 1000));
    }

    printf("WORK_END_NS %llu\n", now_ns());
    fflush(stdout);

    /* clean up scratch files so we don't fill /tmp */
    for (long it = 0; it < iters; it++) {
        char path[600];
        snprintf(path, sizeof path, "%s/iter_%ld.dat", dir, it);
        unlink(path);
    }
    free(buf);
    if (compute > 0) { free(mA); free(mB); free(mC); }

    double elapsed = now_sec() - t0;
    printf("io_bench done: wrote=%llu bytes read=%llu bytes iters=%ld matmul=%ld "
           "matrix_size=%ld checksum=%.6e elapsed=%.2fs\n",
           total_w, total_r, iters, compute, matn, mchecksum, elapsed);
    return 0;
}
