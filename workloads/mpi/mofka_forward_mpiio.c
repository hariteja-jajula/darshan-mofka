/*
 * mofka_forward_mpiio.c -- MPI-IO workload for the Darshan -> Mofka overhead study.
 *
 * This is the MPI counterpart to mofka_forward_smoke.c. It performs collective
 * MPI-IO on a shared file so that Darshan's MPIIO module fires (including the
 * MPI_File_close hook), letting us exercise the MPIIO -> Mofka streaming path the
 * same way the non-MPI smoke test exercises POSIX/STDIO. It intentionally knows
 * nothing about Mofka itself.
 *
 * GENUINE WORK (overhead study requirement): each STEP does a REAL block-sized
 * collective write (IO_BLOCK_KB, default 1 MiB/rank) + fsync + collective read
 * back -- no usleep padding, no 32-byte toy writes. The per-op MPIIO records (and
 * thus the ->Mofka sends) grow linearly with STEPS while OPENS/CLOSES stay fixed,
 * so STEPS is the study's fixed-work scale knob: baseline/runtimeonly/streaming
 * all run the SAME STEPS and we measure each arm's WORK wall. (Fixing wall instead
 * of work would drive wall-overhead to ~0 by construction and hide the signal.)
 *
 * Bounded footprint: every rank writes only its own band [rank*block, +block) and
 * REWRITES that same band each step, so the shared file stays at nprocs*block
 * (e.g. 32 MiB at 32 ranks) regardless of STEPS -- no unbounded Lustre growth.
 *
 * Knobs (env, harness maps them in lib/run.sh workload_env mpi case):
 *   STEPS        collective write+read iterations   (default 1; study sets ~thousands)
 *   IO_BLOCK_KB  per-rank block size per step, KiB  (default 1024 = 1 MiB)
 * (No IO_SLEEP_MS -- the workload is real I/O; pacing by idle sleep is not "work".)
 *
 * Build (use the MPI compiler wrapper):
 *   cc -O2 workloads/mpi/mofka_forward_mpiio.c -o workloads/mpi/mofka_forward_mpiio
 *
 * Run shape (note: NO DARSHAN_ENABLE_NONMPI here -- this is a real MPI job):
 *   mpiexec -n 4 env DARSHAN_MOFKA_ENABLE=1 \
 *       DARSHAN_MOFKA_GROUP_FILE=$PWD/server/mofka.json DARSHAN_MOFKA_TOPIC=darshan \
 *       LD_PRELOAD=/path/to/libdarshan.so \
 *       ./workloads/mpi/mofka_forward_mpiio /tmp/mofka-forward-mpiio
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
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

    MPI_Init(&argc, &argv);
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &nprocs);

    /* STEPS: fixed-work scale knob (see header). <1 -> 1. */
    long steps = 1;
    { const char* s = getenv("STEPS"); if (s && *s) { long v = strtol(s, NULL, 10); if (v > 0) steps = v; } }

    /* IO_BLOCK_KB: real per-rank block written+read each step (genuine I/O, not a
     * 32-byte toy). Default 1 MiB. This is what makes each step meaningful work. */
    long block_kb = 1024;
    { const char* s = getenv("IO_BLOCK_KB"); if (s && *s) { long v = strtol(s, NULL, 10); if (v > 0) block_kb = v; } }
    size_t block = (size_t)block_kb * 1024;

    char* wbuf = malloc(block);
    char* rbuf = malloc(block);
    if (!wbuf || !rbuf) die("malloc");
    memset(wbuf, 'x', block);                      /* fill once, reuse every step */
    /* tag the head of the buffer so the bytes aren't trivially compressible/all-same
     * and so a hexdump identifies the writer rank -- still a real block payload. */
    snprintf(wbuf, block < 32 ? block : 32, "rank-%04d-mpiio", rank);

    /* rank 0 makes the output directory; everyone waits for it */
    if (rank == 0) {
        if (mkdir(dir, 0755) != 0 && errno != EEXIST)
            die("mkdir");
    }
    MPI_Barrier(MPI_COMM_WORLD);

    snprintf(path, sizeof(path), "%s/mpiio-smoke.dat", dir);

    if (MPI_File_open(MPI_COMM_WORLD, path,
                      MPI_MODE_CREATE | MPI_MODE_RDWR, MPI_INFO_NULL, &fh) != MPI_SUCCESS)
        die("MPI_File_open");

    /* Fixed per-rank band: every step rewrites [rank*block, +block). Bounded file. */
    MPI_Offset offset = (MPI_Offset)rank * (MPI_Offset)block;

    /* WORK region self-timing (rank 0), so the overhead study has a valid workload wall
     * that excludes broker/consumer setup + drain. Barrier so the window spans all ranks. */
    MPI_Barrier(MPI_COMM_WORLD);
    double _work_t0 = MPI_Wtime();
    if (rank == 0) { printf("WORK_START_NS %llu\n", (unsigned long long)(_work_t0 * 1e9)); fflush(stdout); }

    unsigned long long bytes_w = 0, bytes_r = 0;
    for (long step = 0; step < steps; step++) {
        if (MPI_File_write_at_all(fh, offset, wbuf, (int)block, MPI_CHAR, &st) != MPI_SUCCESS)
            die("MPI_File_write_at_all");
        bytes_w += (unsigned long long)block;

        if (MPI_File_sync(fh) != MPI_SUCCESS)       /* force the write to storage (real I/O) */
            die("MPI_File_sync");

        MPI_Barrier(MPI_COMM_WORLD);

        if (MPI_File_read_at_all(fh, offset, rbuf, (int)block, MPI_CHAR, &st) != MPI_SUCCESS)
            die("MPI_File_read_at_all");
        bytes_r += (unsigned long long)block;
    }

    if (MPI_File_close(&fh) != MPI_SUCCESS)
        die("MPI_File_close");

    MPI_Barrier(MPI_COMM_WORLD);
    double _work_t1 = MPI_Wtime();

    /* aggregate bytes across ranks so rank 0 can report total genuine I/O volume */
    unsigned long long agg_w = 0, agg_r = 0;
    MPI_Reduce(&bytes_w, &agg_w, 1, MPI_UNSIGNED_LONG_LONG, MPI_SUM, 0, MPI_COMM_WORLD);
    MPI_Reduce(&bytes_r, &agg_r, 1, MPI_UNSIGNED_LONG_LONG, MPI_SUM, 0, MPI_COMM_WORLD);

    if (rank == 0) {
        printf("WORK_END_NS %llu\n", (unsigned long long)(_work_t1 * 1e9));
        MPI_File_delete(path, MPI_INFO_NULL);
        printf("mofka_forward_mpiio complete: %d ranks x %ld steps x %ld KiB/block, "
               "wrote=%.1f MiB read=%.1f MiB in %s (WORK %.2f s)\n",
               nprocs, steps, block_kb,
               agg_w / (1024.0 * 1024.0), agg_r / (1024.0 * 1024.0),
               dir, _work_t1 - _work_t0);
        fflush(stdout);
    }

    free(wbuf);
    free(rbuf);
    MPI_Finalize();
    return 0;
}
