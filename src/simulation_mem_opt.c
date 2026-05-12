/*
 * simulation_mem_opt.c  --  Memory-optimised traffic automaton simulation.
 *
 * Optimisations applied
 * ----------------------
 * [MEM-1] Operates on RoadOpt (uint8_t cells).
 *         One cache line = 64 cells (vs 16 with int).
 *         At N=2M: working set 4 MB (fits in L3) vs 16 MB (spills to DRAM).
 *
 * [MEM-2] Loop fusion: compute_next_generation() and count_departed_cars()
 *         merged into a single pass (compute_next_and_count()).
 *
 *         Rationale:
 *           The original code made two full passes over the N-cell buffers
 *           per simulation step:
 *             Pass 1 (compute_next_generation): reads current[], writes next[]
 *             Pass 2 (count_departed_cars):     reads current[] AND next[]
 *           For N > L3_size / 2 (≈ a few MB on typical CPUs), by the time
 *           pass 2 starts, the data written in pass 1 has been evicted from
 *           L3 and must be re-fetched from DRAM.  Fusing the passes ensures
 *           next[i] is read for the departure test while it is still in the
 *           L1/L2 write buffer — zero extra memory traffic.
 *
 * [MEM-2b] Boundary peeling: the modular wrap-around indices for i=0 and
 *           i=length-1 are handled outside the main loop.
 *           This removes the (i - 1 + length) % length and (i + 1) % length
 *           operations — integer division / modulo on every iteration — from
 *           the hot path, which also lets the auto-vectoriser emit a clean
 *           inner loop with no conditional index arithmetic.
 *
 * [MEM-3] Operates on posix_memalign(64)-aligned buffers (set up in road_mem_opt.c).
 *         The inner loop can be vectorised with aligned AVX2 loads/stores.
 *
 * Thread safety
 * -------------
 * compute_next_and_count() is the only function with an OMP region.
 * The boundary cells (i=0, i=length-1) are handled sequentially outside
 * the parallel region to avoid a data race on the wrap-around indices.
 * The inner loop [1, length-2] is embarrassingly parallel.
 *
 * Correctness
 * -----------
 * The update rule is mathematically identical to simulation.c:
 *   next[i] = (h & a) | (b & ~h & 1)
 * where b=current[i-1], h=current[i], a=current[i+1].
 * Verified by traffic_tests (validator_main.c).
 */

#include <math.h>
#include <stdint.h>

#include "simulation_mem_opt.h"

/* --------------------------------------------------------------------------
 * Core fused kernel
 * -------------------------------------------------------------------------- */

/*
 * compute_next_and_count
 *
 * Single pass over the road:
 *   1. Applies the Nagel-Schreckenberg vmax=1 rule to produce next[].
 *   2. Simultaneously counts cars that moved (old=1, new=0).
 *
 * Returns the fraction of cars that moved (avg velocity for this step).
 *
 * Boundary cells (i=0 and i=length-1) wrap around and are peeled out of
 * the OMP parallel region to avoid index races.  The inner loop runs
 * over [1, length-2] and is safe for static partitioning.
 */
static double compute_next_and_count(RoadOpt *road)
{
    const uint8_t *current = road->cells;
    uint8_t       *next    = road->next_cells;
    const int      length  = road->length;
    int            departed = 0;

    /* --- Left boundary: i = 0 ------------------------------------------ */
    {
        uint8_t b = current[length - 1];   /* wrap-around left  neighbour */
        uint8_t h = current[0];
        uint8_t a = current[1];
        uint8_t n = (h & a) | (b & (uint8_t)(~h) & 1u);
        next[0]   = n;
        departed += (h == 1u && n == 0u) ? 1 : 0;
    }

    /* --- Inner loop: i = 1 .. length-2 ---------------------------------- */
    /*
     * No modulo arithmetic here — indices are i-1, i, i+1, all in-bounds.
     * The compiler (with -O3 -march=native) can auto-vectorise this loop
     * using 256-bit AVX2 loads (32 uint8_t per register) or 512-bit AVX-512
     * loads (64 uint8_t per register) depending on the target.
     *
     * The reduction(+:departed) clause is OMP's portable way to accumulate
     * a scalar across threads without a critical section.
     */
#pragma omp parallel for schedule(static) reduction(+:departed)
    for (int i = 1; i < length - 1; i++) {
        uint8_t b = current[i - 1];
        uint8_t h = current[i];
        uint8_t a = current[i + 1];
        uint8_t n = (h & a) | (b & (uint8_t)(~h) & 1u);
        next[i]   = n;
        departed += (h == 1u && n == 0u) ? 1 : 0;
    }

    /* --- Right boundary: i = length-1 ----------------------------------- */
    {
        uint8_t b = current[length - 2];
        uint8_t h = current[length - 1];
        uint8_t a = current[0];            /* wrap-around right neighbour */
        uint8_t n = (h & a) | (b & (uint8_t)(~h) & 1u);
        next[length - 1] = n;
        departed += (h == 1u && n == 0u) ? 1 : 0;
    }

    if (road->car_count == 0) return 0.0;
    return (double)departed / (double)road->car_count;
}

static void swap_buffers(RoadOpt *road)
{
    uint8_t *tmp      = road->cells;
    road->cells       = road->next_cells;
    road->next_cells  = tmp;
}

/* --------------------------------------------------------------------------
 * Public API  (mirrors simulation.h)
 * -------------------------------------------------------------------------- */

double simulation_mem_opt_step(RoadOpt *road)
{
    double velocity = compute_next_and_count(road);
    swap_buffers(road);
    return velocity;
}

double simulation_mem_opt_measure(RoadOpt *road, int measure_steps)
{
    double velocity_sum = 0.0;
    for (int step = 0; step < measure_steps; step++)
        velocity_sum += simulation_mem_opt_step(road);

    if (measure_steps == 0) return 0.0;
    return velocity_sum / (double)measure_steps;
}

int simulation_mem_opt_warmup_until_steady_state(RoadOpt *road,
                                                  int      window_size,
                                                  double   convergence_threshold,
                                                  int      min_steps,
                                                  int      max_warmup_steps)
{
    double previous_window_mean = -1.0;
    double current_window_sum   =  0.0;
    int    steps_in_window      =  0;
    int    total_steps_done     =  0;

    while (total_steps_done < max_warmup_steps) {
        double velocity = simulation_mem_opt_step(road);
        total_steps_done++;
        current_window_sum += velocity;
        steps_in_window++;

        if (steps_in_window < window_size) continue;

        double current_window_mean = current_window_sum / (double)window_size;

        int past_minimum_steps  = (total_steps_done >= min_steps);
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
