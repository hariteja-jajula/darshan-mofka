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
 * Defaults ~= 16 iters * 16 MiB * 2 (write+read) ~= 512 MiB total, moderate.
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

int main(int argc, char** argv)
{
    const char* dir = (argc > 1) ? argv[1] : "/tmp/dm-iobench";

    long size_mb  = env_long("IO_SIZE_MB",  16);
    long iters    = env_long("IO_ITERS",    16);
    long sleep_ms = env_long("IO_SLEEP_MS", 50);
    long block_kb = env_long("IO_BLOCK_KB", 1024);
    if (size_mb  < 1) size_mb  = 1;
    if (iters    < 1) iters    = 1;
    if (sleep_ms < 0) sleep_ms = 0;
    if (block_kb < 1) block_kb = 1;

    size_t block   = (size_t)block_kb * 1024;
    size_t target  = (size_t)size_mb  * 1024 * 1024;
    long   nblocks = (long)(target / block);            /* whole blocks per iter */
    if (nblocks < 1) nblocks = 1;
    size_t iter_bytes = (size_t)nblocks * block;

    printf("io_bench: size_mb=%ld iters=%ld sleep_ms=%ld block_kb=%ld "
           "(~%ld MiB write + read per iter)\n",
           size_mb, iters, sleep_ms, block_kb,
           (long)(iter_bytes / (1024 * 1024)));

    if (mkdir(dir, 0755) != 0 && errno != EEXIST) die("mkdir");

    char* buf = malloc(block);
    if (!buf) die("malloc");
    memset(buf, 'x', block);                            /* fill once, reuse */

    unsigned long long total_w = 0, total_r = 0;
    double t0 = now_sec();

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

        if (sleep_ms > 0) usleep((useconds_t)(sleep_ms * 1000));
    }

    /* clean up scratch files so we don't fill /tmp */
    for (long it = 0; it < iters; it++) {
        char path[600];
        snprintf(path, sizeof path, "%s/iter_%ld.dat", dir, it);
        unlink(path);
    }
    free(buf);

    double elapsed = now_sec() - t0;
    printf("io_bench done: wrote=%llu bytes read=%llu bytes iters=%ld elapsed=%.2fs\n",
           total_w, total_r, iters, elapsed);
    return 0;
}
