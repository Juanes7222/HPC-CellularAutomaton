#include "simulation_mpi.h"
#include "mpi_common.h"

#include <math.h>

/* -------------------------------------------------------------------------- */
/* Automaton rule                                                              */
/* -------------------------------------------------------------------------- */

/*
 * b = cell behind (i-1), h = cell here (i), a = cell ahead (i+1).
 *
 * Truth table:
 *   h=0 → result = b   (empty cell fills if a car was immediately behind)
 *   h=1 → result = a   (car stays if blocked, moves away if ahead is free)
 *
 * Equivalent to: (h & a) | (b & ~h & 1u)
 */
static inline uint8_t update_cell(uint8_t b, uint8_t h, uint8_t a) {
    return (uint8_t)((h & a) | (b & (uint8_t)(~h) & 1u));
}

/* -------------------------------------------------------------------------- */
/* Buffer management                                                           */
/* -------------------------------------------------------------------------- */

static void swap_buffers(RoadMPI *road) {
    uint8_t *tmp    = road->cells;
    road->cells     = road->next_cells;
    road->next_cells = tmp;
}

/* -------------------------------------------------------------------------- */
/* Halo exchange                                                               */
/* -------------------------------------------------------------------------- */

/*
 * Posts two non-blocking receives and two non-blocking sends.
 *
 * Each process sends:
 *   cells[0]              → left_rank  (becomes right_halo of left neighbour)
 *   cells[local_length-1] → right_rank (becomes left_halo  of right neighbour)
 *
 * Each process receives:
 *   left_halo  from left_rank  (its cells[local_length-1], sent with TAG_SEND_RIGHT)
 *   right_halo from right_rank (its cells[0],              sent with TAG_SEND_LEFT)
 *
 * requests[0..3] must be waited on by the caller before reading the halos.
 */
static void post_halo_exchange(const RoadMPI *road,
                               uint8_t *left_halo,
                               uint8_t *right_halo,
                               MPI_Request requests[4]) {
    int last = road->local_length - 1;

    MPI_Irecv(left_halo,  1, MPI_UINT8_T, road->left_rank,  TAG_SEND_RIGHT,
              road->comm, &requests[0]);
    MPI_Irecv(right_halo, 1, MPI_UINT8_T, road->right_rank, TAG_SEND_LEFT,
              road->comm, &requests[1]);

    MPI_Isend(&road->cells[0],    1, MPI_UINT8_T, road->left_rank,  TAG_SEND_LEFT,
              road->comm, &requests[2]);
    MPI_Isend(&road->cells[last], 1, MPI_UINT8_T, road->right_rank, TAG_SEND_RIGHT,
              road->comm, &requests[3]);
}

/* -------------------------------------------------------------------------- */
/* Distributed kernel                                                          */
/* -------------------------------------------------------------------------- */

/*
 * Executes one full automaton step:
 *   1. Post non-blocking halo exchange.
 *   2. Compute interior cells (overlap with communication).
 *   3. Wait for halos.
 *   4. Compute boundary cells using halos.
 *   5. Global reduction to count departed cars.
 *
 * Returns the global average velocity for this step.
 * Does NOT swap buffers; that is the caller's responsibility.
 */
static double compute_next_and_count_distributed(RoadMPI *road) {
    if (road->global_car_count == 0) {
        int zero = 0, unused = 0;
        MPI_Allreduce(&zero, &unused, 1, MPI_INT, MPI_SUM, road->comm);
        return 0.0;
    }

    const int len    = road->local_length;
    uint8_t  *cur    = road->cells;
    uint8_t  *nxt    = road->next_cells;
    int local_departed = 0;

    uint8_t left_halo, right_halo;
    MPI_Request requests[4];
    post_halo_exchange(road, &left_halo, &right_halo, requests);

    /* Interior: no dependency on halos; runs while network carries boundary data. */
    if (len >= 3) {
        for (int i = 1; i < len - 1; i++) {
            nxt[i]          = update_cell(cur[i - 1], cur[i], cur[i + 1]);
            local_departed += (cur[i] == 1u && nxt[i] == 0u) ? 1 : 0;
        }
    }

    MPI_Waitall(4, requests, MPI_STATUSES_IGNORE);

    /* Boundary cells require halos. */
    if (len == 1) {
        nxt[0]          = update_cell(left_halo, cur[0], right_halo);
        local_departed += (cur[0] == 1u && nxt[0] == 0u) ? 1 : 0;
    } else {
        /* left border */
        nxt[0]          = update_cell(left_halo, cur[0], cur[1]);
        local_departed += (cur[0] == 1u && nxt[0] == 0u) ? 1 : 0;

        /* right border */
        nxt[len - 1]    = update_cell(cur[len - 2], cur[len - 1], right_halo);
        local_departed += (cur[len - 1] == 1u && nxt[len - 1] == 0u) ? 1 : 0;
    }

    int global_departed = 0;
    MPI_Allreduce(&local_departed, &global_departed, 1, MPI_INT, MPI_SUM, road->comm);

    return (double)global_departed / (double)road->global_car_count;
}

/* -------------------------------------------------------------------------- */
/* Public API                                                                  */
/* -------------------------------------------------------------------------- */

double simulation_mpi_step(RoadMPI *road) {
    double velocity = compute_next_and_count_distributed(road);
    swap_buffers(road);
    return velocity;
}

double simulation_mpi_measure(RoadMPI *road, int measure_steps) {
    if (measure_steps <= 0) return 0.0;
    double total = 0.0;
    for (int i = 0; i < measure_steps; i++)
        total += simulation_mpi_step(road);
    return total / (double)measure_steps;
}

/*
 * Mirrors simulation_mem_opt_warmup_until_steady_state exactly.
 * Accumulates window_size steps, computes the window mean, then compares
 * it to the previous window mean.  Convergence is declared when
 * |current_mean - previous_mean| < convergence_threshold and at least
 * min_steps have elapsed.  The accumulator resets after each complete window.
 *
 * Because all processes obtain the same velocity from MPI_Allreduce,
 * the convergence decision is SPMD-identical across ranks with no extra
 * coordination.
 */
int simulation_mpi_warmup_until_steady_state(RoadMPI *road,
                                             int window_size,
                                             double convergence_threshold,
                                             int min_steps,
                                             int max_warmup_steps) {
    double previous_window_mean = -1.0;
    double current_window_sum   =  0.0;
    int    steps_in_window      =  0;
    int    total_steps_done     =  0;

    while (total_steps_done < max_warmup_steps) {
        double velocity = simulation_mpi_step(road);
        total_steps_done++;
        current_window_sum += velocity;
        steps_in_window++;

        if (steps_in_window < window_size) continue;

        double current_window_mean = current_window_sum / (double)window_size;

        int past_minimum_steps   = (total_steps_done >= min_steps);
        int have_previous_window = (previous_window_mean >= 0.0);

        if (past_minimum_steps && have_previous_window) {
            double delta = fabs(current_window_mean - previous_window_mean);
            if (delta < convergence_threshold) break;
        }

        previous_window_mean = current_window_mean;
        current_window_sum   = 0.0;
        steps_in_window      = 0;
    }

    return total_steps_done;
}