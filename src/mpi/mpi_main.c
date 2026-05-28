#include <mpi.h>
#include <stdio.h>
#include <stdlib.h>

#include "road_mpi.h"
#include "simulation_mpi.h"

#define EXPECTED_ARGC                5
#define WARMUP_WINDOW_SIZE           50
#define WARMUP_CONVERGENCE_THRESHOLD 1e-4
#define WARMUP_MIN_STEPS             200

int main(int argc, char *argv[]) {
    MPI_Init(&argc, &argv);

    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    if (argc != EXPECTED_ARGC) {
        if (rank == 0)
            fprintf(stderr,
                    "usage: %s road_length density max_warmup_steps measure_steps\n",
                    argv[0]);
        MPI_Finalize();
        return EXIT_FAILURE;
    }

    int    road_length      = atoi(argv[1]);
    double density          = atof(argv[2]);
    int    max_warmup_steps = atoi(argv[3]);
    int    measure_steps    = atoi(argv[4]);

    RoadMPI *road = road_mpi_create(road_length, density, MPI_COMM_WORLD);
    if (!road) {
        if (rank == 0)
            fprintf(stderr, "error: failed to create distributed road\n");
        MPI_Finalize();
        return EXIT_FAILURE;
    }

    int warmup_steps = simulation_mpi_warmup_until_steady_state(
        road,
        WARMUP_WINDOW_SIZE,
        WARMUP_CONVERGENCE_THRESHOLD,
        WARMUP_MIN_STEPS,
        max_warmup_steps
    );

    if (rank == 0)
        fprintf(stderr, "warmup converged after %d steps\n", warmup_steps);

    MPI_Barrier(MPI_COMM_WORLD);

    double t_start      = MPI_Wtime();
    double avg_velocity = simulation_mpi_measure(road, measure_steps);
    double elapsed      = MPI_Wtime() - t_start;

    double max_elapsed;
    MPI_Reduce(&elapsed, &max_elapsed, 1, MPI_DOUBLE, MPI_MAX, 0, MPI_COMM_WORLD);

    /* Single output line on rank 0: wall_time_ms avg_velocity */
    if (rank == 0)
        printf("%.3f %.6f\n", max_elapsed * 1000.0, avg_velocity);

    road_mpi_destroy(road);
    MPI_Finalize();
    return EXIT_SUCCESS;
}