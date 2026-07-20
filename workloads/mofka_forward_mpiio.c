/*
 * mofka_forward_mpiio.c -- tiny manual MPI-IO smoke workload for Darshan -> Mofka.
 *
 * This is the MPI counterpart to mofka_forward_smoke.c. It performs MPI-IO on a
 * shared file so that Darshan's MPIIO module fires (including the MPI_File_close
 * hook), letting us exercise the MPIIO -> Mofka streaming path the same way the
 * non-MPI smoke test exercises POSIX/STDIO. It intentionally knows nothing about
 * Mofka itself.
 *
 * Build (use the MPI compiler wrapper):
 *   cc -O2 workloads/mofka_forward_mpiio.c -o workloads/mofka_forward_mpiio
 *   # or: mpicc -O2 workloads/mofka_forward_mpiio.c -o workloads/mofka_forward_mpiio
 *
 * Run shape (note: NO DARSHAN_ENABLE_NONMPI here -- this is a real MPI job):
 *   mpiexec -n 4 env DARSHAN_MOFKA_ENABLE=1 \
 *       DARSHAN_MOFKA_GROUP_FILE=$PWD/server/mofka.json DARSHAN_MOFKA_TOPIC=darshan \
 *       LD_PRELOAD=/path/to/libdarshan.so \
 *       ./workloads/mofka_forward_mpiio /tmp/mofka-forward-mpiio
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <mpi.h>

static void die(const char* msg)
{
    perror(msg);
    MPI_Abort(MPI_COMM_WORLD, 1);
}

int main(int argc, char** argv)
{
    const char* dir = (argc > 1) ? argv[1] : "/tmp";
    char path[512];
    int rank, nprocs;
    MPI_File fh;
    MPI_Status st;
    char wbuf[32];
    char rbuf[32];

    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &nprocs);

    /* rank 0 makes the output directory; everyone waits for it */
    if (rank == 0) {
        if (mkdir(dir, 0755) != 0 && errno != EEXIST)
            die("mkdir");
    }
    MPI_Barrier(MPI_COMM_WORLD);

    snprintf(path, sizeof(path), "%s/mpiio-smoke.dat", dir);

    /* Each rank writes a fixed-size block at its own offset in a shared file.
     * Collective open/write/read/close so the MPIIO module records activity and
     * fires its close hook on every rank. */
    memset(wbuf, 0, sizeof(wbuf));
    snprintf(wbuf, sizeof(wbuf), "rank-%04d-mpiio\n", rank);

    if (MPI_File_open(MPI_COMM_WORLD, path,
                      MPI_MODE_CREATE | MPI_MODE_RDWR, MPI_INFO_NULL, &fh) != MPI_SUCCESS)
        die("MPI_File_open");

    MPI_Offset offset = (MPI_Offset)rank * (MPI_Offset)sizeof(wbuf);

    if (MPI_File_write_at_all(fh, offset, wbuf, sizeof(wbuf), MPI_CHAR, &st) != MPI_SUCCESS)
        die("MPI_File_write_at_all");

    if (MPI_File_sync(fh) != MPI_SUCCESS)
        die("MPI_File_sync");

    MPI_Barrier(MPI_COMM_WORLD);

    if (MPI_File_read_at_all(fh, offset, rbuf, sizeof(rbuf), MPI_CHAR, &st) != MPI_SUCCESS)
        die("MPI_File_read_at_all");

    if (MPI_File_close(&fh) != MPI_SUCCESS)
        die("MPI_File_close");

    if (rank == 0) {
        MPI_File_delete(path, MPI_INFO_NULL);
        printf("mofka_forward_mpiio complete: %d ranks wrote/read shared MPI-IO file in %s\n",
               nprocs, dir);
    }

    MPI_Finalize();
    return 0;
}
