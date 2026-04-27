#include <math.h>
#include "simulation.h"

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

double simulation_measure(Road *road, int measure_steps)
{
    double velocity_sum = 0.0;
    for (int step = 0; step < measure_steps; step++)
        velocity_sum += simulation_step(road);

    if (measure_steps == 0) return 0.0;
    return velocity_sum / (double)measure_steps;
}

int simulation_warmup_until_steady_state(Road   *road,
                                         int     window_size,
                                         double  convergence_threshold,
                                         int     min_steps,
                                         int     max_warmup_steps)
{
    double previous_window_mean = -1.0;  /* sentinel: no previous window yet */
    double current_window_sum   =  0.0;
    int    steps_in_window      =  0;
    int    total_steps_done     =  0;

    while (total_steps_done < max_warmup_steps) {
        double velocity = simulation_step(road);
        total_steps_done++;
        current_window_sum += velocity;
        steps_in_window++;

        if (steps_in_window < window_size) continue;

        double current_window_mean = current_window_sum / (double)window_size;

        int past_minimum_steps   = total_steps_done >= min_steps;
        int have_previous_window = previous_window_mean >= 0.0;

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