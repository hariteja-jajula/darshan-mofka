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

#define NFILES  3
#define NWRITES 10
#define NREADS  5
#define BUFSZ   4096

int main(int argc, char** argv)
{
    const char* dir = (argc > 1) ? argv[1] : "/tmp";
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
    return 0;
}
