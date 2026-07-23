/*
 * mofka_forward_loop.c -- heavy looping I/O workload for the Darshan->Mofka
 * throughput / overhead experiments. Unlike mofka_forward_smoke.c (which touches
 * 2 files -> ~13 events), this drives a configurable number of write() calls so
 * the connector emits thousands of send events -- enough for partition
 * parallelism and overhead to be measurable.
 *
 * argv: dir nfiles nwrites bufbytes   (emits ~nfiles*(nwrites+~4) POSIX events)
 * Build:  cc -O2 workloads/c/mofka_forward_loop.c -o workloads/c/mofka_forward_loop
 * Run under LD_PRELOAD=libdarshan.so with DARSHAN_MOFKA_ENABLE=1 like the smoke test.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

int main(int argc, char** argv)
{
    const char* dir = argc > 1 ? argv[1] : "/tmp/dmloop";
    long nf = argc > 2 ? atol(argv[2]) : 1;
    long nw = argc > 3 ? atol(argv[3]) : 50000;
    size_t bs = argc > 4 ? (size_t)atol(argv[4]) : 4096;
    char* buf = malloc(bs);
    if (!buf) { perror("malloc"); return 1; }
    memset(buf, 'x', bs);
    if (mkdir(dir, 0755) && errno != EEXIST) { perror("mkdir"); return 1; }
    for (long f = 0; f < nf; f++) {
        char p[600];
        snprintf(p, sizeof p, "%s/f_%ld.dat", dir, f);
        int fd = open(p, O_CREAT | O_TRUNC | O_WRONLY, 0644);
        if (fd < 0) { perror("open"); return 1; }
        for (long i = 0; i < nw; i++)
            if (write(fd, buf, bs) != (ssize_t)bs) { perror("write"); return 1; }
        if (close(fd)) { perror("close"); return 1; }
        unlink(p);
    }
    printf("loop done: %ld files x %ld writes x %zu B\n", nf, nw, bs);
    free(buf);
    return 0;
}
