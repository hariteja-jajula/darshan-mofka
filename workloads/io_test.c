/*
 * io_test.c -- a tiny, predictable I/O workload for testing the
 * darshan -> mofka connector. It does a KNOWN number of POSIX ops so you
 * can count them on the consumer side:
 *
 *   per file:  1 open + NWRITES writes + NREADS reads + 1 close
 *   total   :  NFILES * (2 + NWRITES + NREADS) events
 *
 * With the defaults below (3 files, 10 writes, 5 reads) that is
 *   3 * (2 + 10 + 5) = 51 events pushed to mofka.
 *
 * Build:  gcc io_test.c -o io_test
 * Run  :  LD_PRELOAD=<libdarshan.so> ./io_test [outdir]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>

#define BUFSZ   4096   /* NFILES/NWRITES/NREADS are env-configurable (see main) */

int main(int argc, char** argv)
{
    const char* dir = (argc > 1) ? argv[1] : "/tmp";
    /* event volume is env-tunable for the overhead study; defaults = original 3/10/5 */
    int NFILES  = getenv("IO_NFILES")  ? atoi(getenv("IO_NFILES"))  : 3;
    int NWRITES = getenv("IO_NWRITES") ? atoi(getenv("IO_NWRITES")) : 10;
    int NREADS  = getenv("IO_NREADS")  ? atoi(getenv("IO_NREADS"))  : 5;
    char buf[BUFSZ];
    memset(buf, 'x', sizeof(buf));

    int total = 0;
    for (int f = 0; f < NFILES; f++) {
        char path[256];
        snprintf(path, sizeof(path), "%s/io_test_%d.dat", dir, f);

        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) { perror("open(write)"); return 1; }
        for (int i = 0; i < NWRITES; i++) {
            if (write(fd, buf, sizeof(buf)) != sizeof(buf)) { perror("write"); return 1; }
        }
        close(fd);

        fd = open(path, O_RDONLY);
        if (fd < 0) { perror("open(read)"); return 1; }
        for (int i = 0; i < NREADS; i++) {
            if (read(fd, buf, sizeof(buf)) < 0) { perror("read"); return 1; }
        }
        close(fd);

        total += 2 + NWRITES + NREADS;
        printf("file %d: %s  (%d writes, %d reads)\n", f, path, NWRITES, NREADS);
    }

    printf("io_test done: %d files, %d expected POSIX events\n", NFILES, total);

    /* optional compute pad: busy-spin ~IO_PAD_SEC to model a compute-bound app doing
       periodic I/O, so wall≈pad while the event set stays fixed (overhead % becomes
       realistic; the delta vs native is unchanged). No I/O here -> no new events. */
    double pad = getenv("IO_PAD_SEC") ? atof(getenv("IO_PAD_SEC")) : 0.0;
    if (pad > 0) {
        struct timespec a, b; clock_gettime(CLOCK_MONOTONIC, &a);
        volatile double acc = 0.0;
        for (;;) {
            for (int k = 0; k < 200000; k++) acc += k * 1.0000001;
            clock_gettime(CLOCK_MONOTONIC, &b);
            if ((b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9 >= pad) break;
        }
    }
    return 0;
}
