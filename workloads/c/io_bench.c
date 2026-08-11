/*
 * io_bench.c -- REALISTIC C training-style workload for the Darshan -> Mofka stream.
 *
 * This is the C twin of workloads/python-ml/train.py: instead of a toy that just
 * writes+rereads a file, it models a real numpy/torch-style ML data pipeline:
 *   * a dataset is written ONCE as N shard files (one buffered write per shard),
 *     the way any real pipeline stages its data to disk;
 *   * every epoch RE-READS all shards from disk (real POSIX read traffic) and runs
 *     a genuine dense matmul over each shard (real per-core compute that overlaps
 *     cleanly with the background stream -- the python-ml regime, not a spin loop);
 *   * model "checkpoints" (weight matrices) are written periodically with a real
 *     multi-block write, like np.savez -- not an 8-byte placeholder.
 * POSIX I/O only -- no Mofka calls; Darshan (LD_PRELOAD=libdarshan.so) instruments
 * it and the connector streams the records.
 *
 * Why realistic (vs the old pure-I/O / spin-compute io_bench): the compute is a
 * cache-tiled dense matmul that keeps the core busy with useful FLOPs and overlaps
 * with the drain thread, so streaming overhead reflects a real compute-bound app
 * (target: single-digit %), not an adversarial memory-latency microbenchmark.
 *
 * Knobs (env vars; the harness lib/run.sh forwards these for io_bench):
 *   IO_ITERS     epochs (re-read + train passes over the dataset)   (default 16)
 *   ML_FILES     dataset shard count                                (default 8)
 *   IO_SIZE_MB   MiB per shard                                      (default 16)
 *   IO_BLOCK_KB  write/read block size, KiB                         (default 1024)
 *   MATRIX_SIZE  matmul dimension N (compute per shard per epoch)   (default 512)
 *   COMPUTE      matmuls per shard per epoch                        (default 1)
 *   CHECKPOINT_EVERY  write a checkpoint every K epochs (0=off)     (default 4)
 *   IO_SLEEP_MS  optional pacing sleep between epochs, ms           (default 0)
 * (COMPUTE_MODE is accepted for backward-compat but ignored: compute is real matmul.)
 *
 * Prints WORK_START_NS/WORK_END_NS (CLOCK_MONOTONIC) around the work region and a
 * CPU_PROBE line, exactly like before, so the overhead-study driver and extractor
 * are unchanged. Final banner keeps the io_bench prefix + elapsed=... field.
 *
 * Build: cc -O2 workloads/c/io_bench.c -o workloads/c/io_bench
 * argv[1] = scratch dir for the dataset/checkpoint files (created if needed).
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/resource.h>

/* CPU-time over the WORK region: RUSAGE_SELF = whole process (all threads),
 * RUSAGE_THREAD = just this (main compute) thread. Same probe as the Python twin. */
static double ru_cpu(int who)
{
    struct rusage r;
    if (getrusage(who, &r) != 0) return -1.0;
    return (double)r.ru_utime.tv_sec + (double)r.ru_utime.tv_usec / 1e6
         + (double)r.ru_stime.tv_sec + (double)r.ru_stime.tv_usec / 1e6;
}
#ifndef RUSAGE_THREAD
#define RUSAGE_THREAD 1
#endif

static void die(const char* m) { perror(m); exit(1); }

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

/* Cache-tiled dense NxN multiply C=A*B (ikj order = unit-stride inner loop, the
 * cache-friendly form a real BLAS-like kernel uses -- overlaps with the drain
 * thread instead of thrashing the LLC). A/B/C caller-owned, filled once. We perturb
 * A each rep so the compiler can't hoist, and return a checksum to defeat DCE. */
static double matmul_reps(double* A, double* B, double* C, long n, long reps)
{
    double sum = 0.0;
    for (long r = 0; r < reps; r++) {
        A[r % (n * n)] += 1e-9;                          /* defeat hoisting */
        memset(C, 0, (size_t)n * (size_t)n * sizeof(double));
        for (long i = 0; i < n; i++) {
            const double* Ai = A + i * n;
            double* Ci = C + i * n;
            for (long k = 0; k < n; k++) {
                double aik = Ai[k];
                const double* Bk = B + k * n;
                for (long j = 0; j < n; j++) Ci[j] += aik * Bk[j];  /* unit stride */
            }
        }
        sum += C[(r % n) * n + (r % n)];                 /* defeat DCE */
    }
    return sum;
}

int main(int argc, char** argv)
{
    const char* dir = (argc > 1) ? argv[1] : "/tmp/dm-iobench";

    long epochs    = env_long("IO_ITERS",     16);       /* re-read+train passes */
    long nfiles    = env_long("ML_FILES",      8);       /* dataset shard count */
    long size_mb   = env_long("IO_SIZE_MB",   16);       /* MiB per shard */
    long block_kb  = env_long("IO_BLOCK_KB", 1024);
    long matn      = env_long("MATRIX_SIZE",  512);       /* matmul dimension */
    long compute   = env_long("COMPUTE",       1);       /* matmuls / shard / epoch */
    long ckpt_every= env_long("CHECKPOINT_EVERY", 4);    /* checkpoint cadence */
    long sleep_ms  = env_long("IO_SLEEP_MS",   0);
    if (epochs   < 1) epochs   = 1;
    if (nfiles   < 1) nfiles   = 1;
    if (size_mb  < 1) size_mb  = 1;
    if (block_kb < 1) block_kb = 1;
    if (matn     < 1) matn     = 1;
    if (compute  < 0) compute  = 0;
    if (ckpt_every< 0) ckpt_every = 0;
    if (sleep_ms < 0) sleep_ms = 0;

    size_t block   = (size_t)block_kb * 1024;
    size_t target  = (size_t)size_mb  * 1024 * 1024;
    long   nblocks = (long)(target / block);
    if (nblocks < 1) nblocks = 1;
    size_t shard_bytes = (size_t)nblocks * block;

    printf("io_bench: epochs=%ld files=%ld size_mb=%ld block_kb=%ld matrix_size=%ld "
           "compute=%ld ckpt_every=%ld (realistic C train-style; ~%ld MiB/shard)\n",
           epochs, nfiles, size_mb, block_kb, matn, compute, ckpt_every,
           (long)(shard_bytes / (1024 * 1024)));

    if (mkdir(dir, 0755) != 0 && errno != EEXIST) die("mkdir");

    char* buf = malloc(block);
    if (!buf) die("malloc");
    memset(buf, 'x', block);

    /* matmul buffers: allocate + seed ONCE, reuse every shard/epoch */
    size_t mcells = (size_t)matn * (size_t)matn;
    double *mA = malloc(mcells * sizeof(double));
    double *mB = malloc(mcells * sizeof(double));
    double *mC = malloc(mcells * sizeof(double));
    if (!mA || !mB || !mC) die("malloc matmul");
    for (size_t i = 0; i < mcells; i++) {
        mA[i] = (double)(((long)i * 1103515245L + 12345L) & 0xffff) / 65536.0;
        mB[i] = (double)(((long)i * 22695477L   + 1L)     & 0xffff) / 65536.0;
    }
    double mchecksum = 0.0;

    unsigned long long total_w = 0, total_r = 0;
    double cpu0_self = ru_cpu(RUSAGE_SELF);
    double cpu0_thr  = ru_cpu(RUSAGE_THREAD);
    double t0 = now_sec();
    printf("WORK_START_NS %llu\n", now_ns());
    fflush(stdout);

    /* --- 1. write the dataset ONCE (one buffered write pass per shard) --- */
    for (long f = 0; f < nfiles; f++) {
        char path[600];
        snprintf(path, sizeof path, "%s/shard_%ld.dat", dir, f);
        int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
        if (fd < 0) die("open shard write");
        for (long b = 0; b < nblocks; b++) {
            if (write(fd, buf, block) != (ssize_t)block) die("write shard");
            total_w += block;
        }
        if (fsync(fd) != 0) die("fsync shard");
        if (close(fd) != 0) die("close shard");
    }

    /* --- 2. train: each epoch re-reads every shard + real matmul, periodic ckpt --- */
    for (long ep = 0; ep < epochs; ep++) {
        for (long f = 0; f < nfiles; f++) {
            char path[600];
            snprintf(path, sizeof path, "%s/shard_%ld.dat", dir, f);
            int fd = open(path, O_RDONLY);
            if (fd < 0) die("open shard read");
            ssize_t n;
            while ((n = read(fd, buf, block)) > 0) total_r += (unsigned long long)n;
            if (n < 0) die("read shard");
            if (close(fd) != 0) die("close shard read");

            if (compute > 0)
                mchecksum += matmul_reps(mA, mB, mC, matn, compute);   /* real compute */
        }

        /* per-epoch training log via buffered stdio (fopen/fprintf/fclose) -- exercises
         * the STDIO module and, crucially, CLOSES the stream each epoch so Darshan emits
         * an STDIO close record (with its counter snapshot) into the stream. Mirrors a
         * real trainer appending to a metrics/log file. */
        {
            char lpath[600];
            snprintf(lpath, sizeof lpath, "%s/train_log_%ld.txt", dir, ep);
            FILE *lf = fopen(lpath, "w");
            if (lf) {
                fprintf(lf, "epoch %ld: read=%llu bytes checksum=%.6e\n",
                        ep, total_r, mchecksum);
                fclose(lf);   /* terminal STDIO op -> emits the close record */
            }
        }

        /* periodic checkpoint: a real multi-block weight write (np.savez analog) */
        if (ckpt_every > 0 && ((ep + 1) % ckpt_every == 0)) {
            char path[600];
            snprintf(path, sizeof path, "%s/ckpt_%ld.dat", dir, ep);
            int fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
            if (fd < 0) die("open ckpt");
            long ckpt_blocks = nblocks / 4; if (ckpt_blocks < 1) ckpt_blocks = 1;
            for (long b = 0; b < ckpt_blocks; b++) {
                if (write(fd, buf, block) != (ssize_t)block) die("write ckpt");
                total_w += block;
            }
            if (fsync(fd) != 0) die("fsync ckpt");
            if (close(fd) != 0) die("close ckpt");
        }

        if (sleep_ms > 0) usleep((useconds_t)(sleep_ms * 1000));
    }

    printf("WORK_END_NS %llu\n", now_ns());
    { double cpu1_self = ru_cpu(RUSAGE_SELF), cpu1_thr = ru_cpu(RUSAGE_THREAD);
      double wall = now_sec() - t0;
      printf("CPU_PROBE wall=%.2f cpu_self=%.2f cpu_thread=%.2f\n",
             wall, cpu1_self - cpu0_self, cpu1_thr - cpu0_thr); }
    fflush(stdout);

    /* clean up scratch files */
    for (long f = 0; f < nfiles; f++) {
        char path[600];
        snprintf(path, sizeof path, "%s/shard_%ld.dat", dir, f);
        unlink(path);
    }
    for (long ep = 0; ep < epochs; ep++) {
        char path[600];
        snprintf(path, sizeof path, "%s/ckpt_%ld.dat", dir, ep);
        unlink(path);
        snprintf(path, sizeof path, "%s/train_log_%ld.txt", dir, ep);
        unlink(path);
    }
    free(buf); free(mA); free(mB); free(mC);

    double elapsed = now_sec() - t0;
    printf("io_bench done: wrote=%llu bytes read=%llu bytes epochs=%ld files=%ld "
           "matrix_size=%ld checksum=%.6e elapsed=%.2fs\n",
           total_w, total_r, epochs, nfiles, matn, mchecksum, elapsed);
    return 0;
}
