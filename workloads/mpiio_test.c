/*
 * mpiio_test.c -- MPI-IO sibling of io_mpi.c. Where io_mpi.c drives the POSIX
 * module (plain open/read/write, MPI only for launch), THIS workload issues real
 * MPI-IO calls (MPI_File_open / MPI_File_write_at / MPI_File_read_at /
 * MPI_File_close) so it exercises darshan's MPIIO module and the newly-wired
 * MPIIO -> mofka connector send sites.
 *
 * IMPORTANT: darshan must be built WITH MPI for this to produce MPIIO events.
 * The in-repo build.sh configures --without-mpi, so libdarshan.so contains NO
 * MPI_File_* wrappers and this workload streams NOTHING from the MPIIO module.
 * Rebuild darshan with an MPI compiler first (see the study notes).
 *
 * Event math mirrors io_test (one open per file, RDWR):
 *   per rank:  NFILES * (1 open + NWRITES + NREADS + 1 close)
 *           =  NFILES * (2 + NWRITES + NREADS)               (= 51 with the defaults)
 *   total   :  nranks * that
 * Each rank writes to its OWN file (rank in the path) so ranks never collide.
 *
 * Build:  mpicc mpiio_test.c -o mpiio_test
 * Run  :  LD_PRELOAD=<libdarshan.so(with MPI)> mpiexec -n <ranks> ./mpiio_test [outdir]
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mpi.h>

#define NFILES  3
#define NWRITES 10
#define NREADS  5
#define BUFSZ   4096

static void check(int rc, const char* what)
{
    if (rc != MPI_SUCCESS) {
        char msg[MPI_MAX_ERROR_STRING]; int len = 0;
        MPI_Error_string(rc, msg, &len);
        fprintf(stderr, "%s: %s\n", what, msg);
        MPI_Abort(MPI_COMM_WORLD, 1);
    }
}

int main(int argc, char** argv)
{
    MPI_Init(&argc, &argv);
    /* return errors instead of aborting inside the MPI-IO layer, so check() reports them */
    MPI_File_set_errhandler(MPI_FILE_NULL, MPI_ERRORS_RETURN);

    int rank = 0, nranks = 1;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &nranks);

    char host[256];
    if (gethostname(host, sizeof(host)) != 0) snprintf(host, sizeof(host), "unknown");
    host[sizeof(host) - 1] = '\0';

    const char* dir = (argc > 1) ? argv[1] : "/tmp";
    const int verbose = (getenv("MPIIO_TEST_VERBOSE") != NULL);

    char buf[BUFSZ];
    memset(buf, 'x', sizeof(buf));

    /* line up all ranks so the I/O storm hits the connector at once */
    MPI_Barrier(MPI_COMM_WORLD);

    int local_events = 0;
    for (int f = 0; f < NFILES; f++) {
        char path[512];
        /* rank in the name -> no collisions when many ranks share a dir */
        snprintf(path, sizeof(path), "%s/mpiio_test_r%d_f%d.dat", dir, rank, f);

        MPI_File fh;
        MPI_Status st;

        /* one independent (per-rank) file handle, read+write, created fresh */
        check(MPI_File_open(MPI_COMM_SELF, path,
                            MPI_MODE_CREATE | MPI_MODE_RDWR, MPI_INFO_NULL, &fh),
              "MPI_File_open");

        for (int i = 0; i < NWRITES; i++)
            check(MPI_File_write_at(fh, (MPI_Offset)i * BUFSZ, buf, BUFSZ, MPI_BYTE, &st),
                  "MPI_File_write_at");

        /* make sure the writes are visible before we read them back */
        check(MPI_File_sync(fh), "MPI_File_sync");

        for (int i = 0; i < NREADS; i++)
            check(MPI_File_read_at(fh, (MPI_Offset)i * BUFSZ, buf, BUFSZ, MPI_BYTE, &st),
                  "MPI_File_read_at");

        check(MPI_File_close(&fh), "MPI_File_close");

        local_events += 2 + NWRITES + NREADS;
    }

    if (verbose)
        printf("[rank %d/%d on %s] %d files, %d MPIIO events\n",
               rank, nranks, host, NFILES, local_events);

    /* one authoritative total so you can match it against the consumer tally */
    int total_events = 0;
    MPI_Reduce(&local_events, &total_events, 1, MPI_INT, MPI_SUM, 0, MPI_COMM_WORLD);

    MPI_Barrier(MPI_COMM_WORLD);
    if (rank == 0)
        printf("mpiio_test done: %d ranks, %d events/rank, %d expected MPIIO events total\n",
               nranks, local_events, total_events);

    MPI_Finalize();
    return 0;
}
