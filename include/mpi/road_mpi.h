#ifndef ROAD_MPI_H
#define ROAD_MPI_H

#include <stdint.h>
#include <mpi.h>

typedef struct {
    int global_length;
    int local_length;
    int global_offset;

    int global_car_count;
    int local_car_count;

    int rank;
    int size;
    int left_rank;
    int right_rank;

    uint8_t *cells;
    uint8_t *next_cells;

    MPI_Comm comm;
} RoadMPI;

/*
 * Creates and distributes a road of global_length cells seeded with the given
 * density. Rank 0 generates the global state and scatters it to all processes.
 * Returns NULL on error.
 */
RoadMPI *road_mpi_create(int global_length, double density, MPI_Comm comm);

/*
 * Creates a distributed road from an explicit global initial state array.
 * global_state must be valid on all ranks (only rank 0 reads it as scatter source).
 * Useful for reproducible tests in the validator.
 */
RoadMPI *road_mpi_create_with_state(int global_length,
                                    const uint8_t *global_state,
                                    MPI_Comm comm);

/* Frees all local resources. Must be called on all processes. */
void road_mpi_destroy(RoadMPI *road);

/*
 * Fills counts[i] and displs[i] with the block-cyclic distribution of
 * global_length cells across size processes, distributing the remainder
 * to the first (global_length % size) ranks.
 */
void road_mpi_build_distribution(int global_length, int size,
                                 int *counts, int *displs);

/*
 * Gathers the full road into global_cells_out on rank 0.
 * global_cells_out must point to at least global_length bytes on rank 0;
 * it is ignored on all other ranks.
 */
void road_mpi_gather_cells(const RoadMPI *road, uint8_t *global_cells_out);

#endif /* ROAD_MPI_H */
