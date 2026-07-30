#!/bin/bash
cd "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/gate0mpi"
echo "sB1 mpi_hello start host=$(hostname -s) PMI_RANK=${PMI_RANK:-unset} PMI_SIZE=${PMI_SIZE:-unset}" >&2
# NOT stripped: the MPI section keeps its PMI world so MPI_Init can fence.
export SLINGSHOT_VNIS=${SLINGSHOT_VNIS%%,*} SLINGSHOT_SVC_IDS=${SLINGSHOT_SVC_IDS%%,*} SLINGSHOT_DEVICES=${SLINGSHOT_DEVICES%%,*};
exec "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/gate0mpi/mpi_hello" "/lus/eagle/projects/radix-io/hjajula/darshan-mofka-flowcept/darshan-mofka-worktree-stricter-overnight/run_artifacts/gate0mpi/B_ok"
