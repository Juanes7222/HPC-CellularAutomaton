#include <stdio.h>
#include "simulation.h"

/*
 * Computes the next generation into road->next_cells using the traffic rule:
 *
 *   R(t+1, i) = ( R(t,i) AND R(t,i+1) )       <- car blocked, stays
 *             OR ( R(t,i-1) AND NOT R(t,i) )   <- car behind moves in
 *
 * All reads come from road->cells (immutable during this function).
 * All writes go to road->next_cells (distinct allocation).
 * Every iteration is independent -> data-race free -> safe to parallelise.
 *
 * When compiled with -fopenmp the #pragma activates OpenMP parallelism.
 * When compiled without -fopenmp the pragma is silently skipped and
 * the loop runs as a normal sequential for loop. No #ifdef needed.
 */
static void compute_next_generation(Road *road)
{
    const int *current = road->cells;
    int       *next    = road->next_cells;
    const int  length  = road->length;

#pragma omp parallel for schedule(static)
    for (int i = 0; i < length; i++) {
        int cell_behind = current[(i - 1 + length) % length];
        int cell_here   = current[i];
        int cell_ahead  = current[(i + 1) % length];

        next[i] = (cell_here & cell_ahead)
                | (cell_behind & ~cell_here & 1);
    }
}

static int count_departed_cars(const Road *road)
{
    const int *old_cells = road->cells;
    const int *new_cells = road->next_cells;
    const int  length    = road->length;
    int        departed  = 0;

#pragma omp parallel for reduction(+:departed) schedule(static)
    for (int i = 0; i < length; i++)
        departed += (old_cells[i] == 1 && new_cells[i] == 0) ? 1 : 0;

    return departed;
}

static void swap_generation_buffers(Road *road)
{
    int *tmp         = road->cells;
    road->cells      = road->next_cells;
    road->next_cells = tmp;
}

double simulation_step(Road *road)
{
    compute_next_generation(road);
    int cars_that_moved = count_departed_cars(road);
    swap_generation_buffers(road);

    if (road->car_count == 0) return 0.0;
    return (double)cars_that_moved / (double)road->car_count;
}

double simulation_run(Road *road, int warmup_steps, int measure_steps)
{
    for (int step = 0; step < warmup_steps; step++)
        simulation_step(road);

    double velocity_sum = 0.0;
    for (int step = 0; step < measure_steps; step++)
        velocity_sum += simulation_step(road);

    if (measure_steps == 0) return 0.0;
    return velocity_sum / (double)measure_steps;
}