/* Gate-0 probe helper: minimal MPI hello. Runs as one MPMD section alongside a
 * stripped non-MPI bedrock section. If MPI_Init completes and every rank reaches
 * MPI_Finalize, an MPI program CAN coexist with a stripped sibling section under
 * one PALS launch -> the MPI-IO workload is streamable cross-node. If MPI_Init
 * blocks (bedrock never joins the shared PMI fence), it hangs -> fork decision. */
#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    MPI_Init(&argc, &argv);           /* the load-bearing call: shared PMI fence */
    int rank = -1, size = -1;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);
    fprintf(stderr, "mpi_hello: rank=%d size=%d\n", rank, size);
    MPI_Barrier(MPI_COMM_WORLD);
    if (rank == 0 && argc > 1) {       /* verdict flag, written only post-barrier */
        FILE *f = fopen(argv[1], "w");
        if (f) { fprintf(f, "MPI_OK rank0_of_size=%d\n", size); fclose(f); }
    }
    MPI_Finalize();
    return 0;
}
