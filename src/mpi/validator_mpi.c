#include "validator_mpi.h"
#include "road_mpi.h"
#include "simulation_mpi.h"

#include <mpi.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <string.h>

/* -------------------------------------------------------------------------- */
/* Helpers                                                                     */
/* -------------------------------------------------------------------------- */

/*
 * Gathers the current road state into a heap-allocated array on rank 0.
 * Callers on rank 0 must free the returned pointer.
 * Returns NULL on non-root ranks.
 */
static uint8_t *gather_to_rank0(const RoadMPI *road) {
    uint8_t *buf = NULL;
    if (road->rank == 0)
        buf = (uint8_t *)malloc((size_t)road->global_length * sizeof(uint8_t));
    road_mpi_gather_cells(road, buf);
    return buf;
}

/*
 * Broadcasts an int result from rank 0 to all processes so that every rank
 * can make the same pass/fail decision without additional coordination.
 */
static int broadcast_result(int result, MPI_Comm comm) {
    MPI_Bcast(&result, 1, MPI_INT, 0, comm);
    return result;
}

static void report(const char *name, int pass, int rank) {
    if (rank == 0)
        fprintf(stderr, "[%s] %s\n", pass ? "PASS" : "FAIL", name);
}

/* -------------------------------------------------------------------------- */
/* Individual tests                                                            */
/* -------------------------------------------------------------------------- */

static int test_empty_road_velocity_is_zero(void) {
    int n = 8;
    uint8_t state[8] = {0, 0, 0, 0, 0, 0, 0, 0};

    RoadMPI *road = road_mpi_create_with_state(n, state, MPI_COMM_WORLD);
    if (!road) return 0;

    double vel = simulation_mpi_step(road);
    int pass   = (vel == 0.0);

    road_mpi_destroy(road);
    return pass;
}

static int test_full_road_velocity_is_zero(void) {
    int n = 8;
    uint8_t state[8] = {1, 1, 1, 1, 1, 1, 1, 1};

    RoadMPI *road = road_mpi_create_with_state(n, state, MPI_COMM_WORLD);
    if (!road) return 0;

    double vel = simulation_mpi_step(road);
    int pass   = (vel == 0.0);

    road_mpi_destroy(road);
    return pass;
}

static int test_single_car_velocity_is_one(void) {
    int n = 8;
    uint8_t state[8] = {0, 0, 0, 1, 0, 0, 0, 0};

    RoadMPI *road = road_mpi_create_with_state(n, state, MPI_COMM_WORLD);
    if (!road) return 0;

    double vel = simulation_mpi_step(road);
    int pass   = (fabs(vel - 1.0) < 1e-9);

    road_mpi_destroy(road);
    return pass;
}

/*
 * A car at the last global cell (index n-1) must wrap around and appear
 * at index 0 after one step.
 */
static int test_car_wraps_around_boundary(void) {
    int n = 4;
    uint8_t state[4] = {0, 0, 0, 1};

    RoadMPI *road = road_mpi_create_with_state(n, state, MPI_COMM_WORLD);
    if (!road) return 0;

    simulation_mpi_step(road);

    uint8_t *gathered = gather_to_rank0(road);
    int pass = 1;
    if (road->rank == 0) {
        pass = (gathered[0] == 1);
        for (int i = 1; i < n; i++)
            pass = pass && (gathered[i] == 0);
        free(gathered);
    }

    road_mpi_destroy(road);
    return broadcast_result(pass, MPI_COMM_WORLD);
}

/*
 * The total number of cars in the gathered state must equal global_car_count
 * across multiple steps.
 */
static int test_car_count_is_conserved(void) {
    int n = 16;
    uint8_t state[16] = {1, 0, 1, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0, 1, 0, 1};
    int expected = 0;
    for (int i = 0; i < n; i++) expected += state[i];

    RoadMPI *road = road_mpi_create_with_state(n, state, MPI_COMM_WORLD);
    if (!road) return 0;

    uint8_t *gathered = NULL;
    if (road->rank == 0)
        gathered = (uint8_t *)malloc((size_t)n * sizeof(uint8_t));

    int pass = 1;
    for (int t = 0; t < 20 && pass; t++) {
        simulation_mpi_step(road);
        road_mpi_gather_cells(road, gathered);
        if (road->rank == 0) {
            int count = 0;
            for (int i = 0; i < n; i++) count += gathered[i];
            if (count != expected) pass = 0;
        }
        pass = broadcast_result(pass, road->comm);
    }

    if (road->rank == 0) free(gathered);
    road_mpi_destroy(road);
    return pass;
}

/*
 * Compares the MPI result against a hand-computed reference for one step.
 *
 * Initial state: {0, 1, 0, 0, 1, 0, 1, 0}
 *
 * Applying update_cell(b, h, a) = (h & a) | (b & ~h & 1):
 *   i=0: b=0 h=0 a=1 → 0              i=4: b=0 h=1 a=0 → 0
 *   i=1: b=0 h=1 a=0 → 0              i=5: b=1 h=0 a=1 → 1
 *   i=2: b=1 h=0 a=0 → 1              i=6: b=0 h=1 a=0 → 0
 *   i=3: b=0 h=0 a=1 → 0              i=7: b=1 h=0 a=0 → 1
 *
 * Expected after step 1: {0, 0, 1, 0, 0, 1, 0, 1}
 */
static int test_mpi_matches_sequential_reference(void) {
    int n = 8;
    uint8_t initial[8]   = {0, 1, 0, 0, 1, 0, 1, 0};
    uint8_t expected[8]  = {0, 0, 1, 0, 0, 1, 0, 1};

    RoadMPI *road = road_mpi_create_with_state(n, initial, MPI_COMM_WORLD);
    if (!road) return 0;

    simulation_mpi_step(road);

    uint8_t *gathered = gather_to_rank0(road);
    int pass = 1;
    if (road->rank == 0) {
        pass = (memcmp(gathered, expected, (size_t)n) == 0);
        free(gathered);
    }

    road_mpi_destroy(road);
    return broadcast_result(pass, MPI_COMM_WORLD);
}

/*
 * A solitary car at index 0 must advance by 1 position at each step since
 * the road ahead is always free (no other cars).
 */
static int test_single_car_advances_one_cell_per_step(void) {
    int n = 8;
    uint8_t state[8] = {1, 0, 0, 0, 0, 0, 0, 0};

    RoadMPI *road = road_mpi_create_with_state(n, state, MPI_COMM_WORLD);
    if (!road) return 0;

    int pass = 1;
    for (int step = 1; step <= n && pass; step++) {
        simulation_mpi_step(road);
        uint8_t *gathered = gather_to_rank0(road);
        if (road->rank == 0) {
            int expected_pos = step % n;
            for (int i = 0; i < n; i++) {
                int expected_val = (i == expected_pos) ? 1 : 0;
                if (gathered[i] != expected_val) { pass = 0; break; }
            }
            free(gathered);
        }
        pass = broadcast_result(pass, road->comm);
    }

    road_mpi_destroy(road);
    return pass;
}

/* -------------------------------------------------------------------------- */
/* Public entry point                                                          */
/* -------------------------------------------------------------------------- */

int validator_mpi_run_all_tests(void) {
    int rank;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);

    int all_pass = 1;
    int r;

    r = test_empty_road_velocity_is_zero();
    report("empty road: velocity = 0", r, rank);
    all_pass &= r;

    r = test_full_road_velocity_is_zero();
    report("full road: velocity = 0", r, rank);
    all_pass &= r;

    r = test_single_car_velocity_is_one();
    report("single car: velocity = 1", r, rank);
    all_pass &= r;

    r = test_car_wraps_around_boundary();
    report("periodic BC: car wraps around", r, rank);
    all_pass &= r;

    r = test_car_count_is_conserved();
    report("conservation: car count stable over 20 steps", r, rank);
    all_pass &= r;

    r = test_mpi_matches_sequential_reference();
    report("correctness: MPI state matches hand-computed reference", r, rank);
    all_pass &= r;

    r = test_single_car_advances_one_cell_per_step();
    report("correctness: single car advances exactly one cell per step", r, rank);
    all_pass &= r;

    if (rank == 0)
        fprintf(stderr, "\nresult: %s\n", all_pass ? "ALL PASS" : "SOME TESTS FAILED");

    return all_pass;
}
