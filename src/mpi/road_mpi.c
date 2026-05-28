#include "road_mpi.h"
#include "mpi_common.h"

#include <stdlib.h>
#include <stdio.h>
#include <time.h>

/* -------------------------------------------------------------------------- */
/* Private helpers                                                             */
/* -------------------------------------------------------------------------- */

static uint8_t *allocate_aligned_cells(int length) {
    if (length == 0) return NULL;
    void *ptr = NULL;
    if (posix_memalign(&ptr, 64, (size_t)length * sizeof(uint8_t)) != 0)
        return NULL;
    return (uint8_t *)ptr;
}

static void seed_cells_randomly(uint8_t *cells, int length, double density) {
    for (int i = 0; i < length; i++) {
        double sample = (double)rand() / ((double)RAND_MAX + 1.0);
        cells[i] = (sample < density) ? 1u : 0u;
    }
}

static int count_occupied_cells(const uint8_t *cells, int length) {
    int count = 0;
    for (int i = 0; i < length; i++)
        count += cells[i];
    return count;
}

/* -------------------------------------------------------------------------- */
/* Public: distribution utilities                                              */
/* -------------------------------------------------------------------------- */

void road_mpi_build_distribution(int global_length, int size,
                                 int *counts, int *displs) {
    int base = global_length / size;
    int remainder = global_length % size;
    int offset = 0;
    for (int r = 0; r < size; r++) {
        counts[r] = base + (r < remainder ? 1 : 0);
        displs[r]  = offset;
        offset    += counts[r];
    }
}

/* -------------------------------------------------------------------------- */
/* Private: allocation and scatter                                             */
/* -------------------------------------------------------------------------- */

static RoadMPI *allocate_road(int global_length, MPI_Comm comm) {
    RoadMPI *road = (RoadMPI *)malloc(sizeof(RoadMPI));
    if (!road) return NULL;

    int rank, size;
    MPI_Comm_rank(comm, &rank);
    MPI_Comm_size(comm, &size);

    if (size > global_length) {
        if (rank == 0)
            fprintf(stderr,
                    "error: number of processes (%d) exceeds road length (%d)\n",
                    size, global_length);
        free(road);
        return NULL;
    }

    road->comm         = comm;
    road->rank         = rank;
    road->size         = size;
    road->left_rank    = left_rank(rank, size);
    road->right_rank   = right_rank(rank, size);
    road->global_length = global_length;

    int base      = global_length / size;
    int remainder = global_length % size;
    road->local_length  = base + (rank < remainder ? 1 : 0);
    road->global_offset = rank * base + (rank < remainder ? rank : remainder);

    road->cells      = allocate_aligned_cells(road->local_length);
    road->next_cells = allocate_aligned_cells(road->local_length);

    if (!road->cells || !road->next_cells) {
        free(road->cells);
        free(road->next_cells);
        free(road);
        return NULL;
    }

    return road;
}

static void scatter_global_state(RoadMPI *road, const uint8_t *global_state) {
    int *counts = (int *)malloc((size_t)road->size * sizeof(int));
    int *displs = (int *)malloc((size_t)road->size * sizeof(int));
    road_mpi_build_distribution(road->global_length, road->size, counts, displs);

    /*
     * MPI_Scatterv only reads global_state at the root; passing it on
     * non-root processes is harmless and avoids a NULL sendbuf.
     */
    MPI_Scatterv(
        global_state, counts, displs, MPI_UINT8_T,
        road->cells, road->local_length, MPI_UINT8_T,
        0, road->comm
    );

    free(counts);
    free(displs);
}

static void finalize_car_counts(RoadMPI *road) {
    road->local_car_count = count_occupied_cells(road->cells, road->local_length);
    MPI_Allreduce(&road->local_car_count, &road->global_car_count,
                  1, MPI_INT, MPI_SUM, road->comm);
}

/* -------------------------------------------------------------------------- */
/* Public: create / destroy                                                    */
/* -------------------------------------------------------------------------- */

RoadMPI *road_mpi_create(int global_length, double density, MPI_Comm comm) {
    if (global_length <= 0 || density < 0.0 || density > 1.0)
        return NULL;

    RoadMPI *road = allocate_road(global_length, comm);
    if (!road) return NULL;

    uint8_t *global_state = NULL;
    if (road->rank == 0) {
        global_state = (uint8_t *)malloc((size_t)global_length * sizeof(uint8_t));
        if (!global_state) {
            road_mpi_destroy(road);
            return NULL;
        }
        srand((unsigned int)time(NULL));
        seed_cells_randomly(global_state, global_length, density);
    }

    scatter_global_state(road, global_state);

    if (road->rank == 0)
        free(global_state);

    finalize_car_counts(road);
    return road;
}

RoadMPI *road_mpi_create_with_state(int global_length,
                                    const uint8_t *global_state,
                                    MPI_Comm comm) {
    if (global_length <= 0 || !global_state) return NULL;

    RoadMPI *road = allocate_road(global_length, comm);
    if (!road) return NULL;

    scatter_global_state(road, global_state);
    finalize_car_counts(road);
    return road;
}

void road_mpi_destroy(RoadMPI *road) {
    if (!road) return;
    free(road->cells);
    free(road->next_cells);
    free(road);
}

/* -------------------------------------------------------------------------- */
/* Public: gather                                                              */
/* -------------------------------------------------------------------------- */

void road_mpi_gather_cells(const RoadMPI *road, uint8_t *global_cells_out) {
    int *counts = (int *)malloc((size_t)road->size * sizeof(int));
    int *displs = (int *)malloc((size_t)road->size * sizeof(int));
    road_mpi_build_distribution(road->global_length, road->size, counts, displs);

    MPI_Gatherv(
        road->cells, road->local_length, MPI_UINT8_T,
        global_cells_out, counts, displs, MPI_UINT8_T,
        0, road->comm
    );

    free(counts);
    free(displs);
}