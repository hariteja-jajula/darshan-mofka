/*
 * io_mpi.c -- the MPI sibling of io_test.c. Where io_test runs ONE process per
 * node, this activates EVERY core on EVERY node: launch it with one rank per
 * core (mpiexec -n <total_cores> ... --map-by core) and each rank runs the same
 * known POSIX I/O pattern, so the darshan -> mofka connector receives traffic
 * from every core in the allocation at once.
 *
 * The op count per rank is identical to io_test, so the math composes cleanly:
 *
 *   per rank:  1 open + NWRITES writes + NREADS reads + 1 close, per file
 *   per rank:  NFILES * (2 + NWRITES + NREADS) events
 *   total   :  nranks * NFILES * (2 + NWRITES + NREADS) events
 *
 * With the defaults below (3 files, 10 writes, 5 reads) that is 51 events per
 * rank, so e.g. 2 nodes * 128 cores * 51 = 13056 events pushed to mofka.
 *
 * Each rank writes to its OWN files (the path carries the rank), so ranks never
 * collide even when hundreds share a node and a directory. NOTE: the in-repo
 * darshan is a --without-mpi build, so it instruments each rank as an independent
 * process (needs DARSHAN_ENABLE_NONMPI=1) and cannot stamp the MPI rank -- MPI
 * here is only for launch/placement, not for darshan's rank field.
 *
 * Build:  mpicc io_mpi.c -o io_mpi
 * Run  :  LD_PRELOAD=<libdarshan.so> mpiexec -n <ranks> ./io_mpi [outdir]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <mpi.h>

#define NFILES  3
#define NWRITES 10
#define NREADS  5
#define BUFSZ   4096

int main(int argc, char** argv)
{
    MPI_Init(&argc, &argv);

    int rank = 0, nranks = 1;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &nranks);

    char host[256];
    if (gethostname(host, sizeof(host)) != 0) snprintf(host, sizeof(host), "unknown");
    host[sizeof(host) - 1] = '\0';

    const char* dir = (argc > 1) ? argv[1] : "/tmp";
    const int verbose = (getenv("IO_MPI_VERBOSE") != NULL);

    char buf[BUFSZ];
    memset(buf, 'x', sizeof(buf));

    /* line up all ranks so the I/O storm hits the connector at once */
    MPI_Barrier(MPI_COMM_WORLD);

    int local_events = 0;
    for (int f = 0; f < NFILES; f++) {
        char path[512];
        /* rank in the name -> no collisions when many ranks share a dir */
        snprintf(path, sizeof(path), "%s/io_mpi_r%d_f%d.dat", dir, rank, f);

        int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd < 0) { perror("open(write)"); MPI_Abort(MPI_COMM_WORLD, 1); }
        for (int i = 0; i < NWRITES; i++) {
            if (write(fd, buf, sizeof(buf)) != sizeof(buf)) { perror("write"); MPI_Abort(MPI_COMM_WORLD, 1); }
        }
        close(fd);

        fd = open(path, O_RDONLY);
        if (fd < 0) { perror("open(read)"); MPI_Abort(MPI_COMM_WORLD, 1); }
        for (int i = 0; i < NREADS; i++) {
            if (read(fd, buf, sizeof(buf)) < 0) { perror("read"); MPI_Abort(MPI_COMM_WORLD, 1); }
        }
        close(fd);

        local_events += 2 + NWRITES + NREADS;
    }

    if (verbose)
        printf("[rank %d/%d on %s] %d files, %d POSIX events\n",
               rank, nranks, host, NFILES, local_events);

    /* one authoritative total so you can match it against the consumer tally */
    int total_events = 0;
    MPI_Reduce(&local_events, &total_events, 1, MPI_INT, MPI_SUM, 0, MPI_COMM_WORLD);

    MPI_Barrier(MPI_COMM_WORLD);
    if (rank == 0)
        printf("io_mpi done: %d ranks, %d events/rank, %d expected POSIX events total\n",
               nranks, local_events, total_events);

    MPI_Finalize();
    return 0;
}
