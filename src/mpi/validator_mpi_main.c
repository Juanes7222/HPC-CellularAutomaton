#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>

#include "validator_mpi.h"

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;

    MPI_Init(&argc, &argv);

    int rank;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);

    if (rank == 0)
        fprintf(stderr, "running MPI cellular automaton validator\n\n");

    int pass = validator_mpi_run_all_tests();

    MPI_Finalize();
    return pass ? EXIT_SUCCESS : EXIT_FAILURE;
}
