#ifndef SIMULATION_H
#define SIMULATION_H

#include "road.h"

/*
 * Advances the road by one time step.
 * Returns the average car velocity for that step (cars_moved / total_cars).
 *
 * When compiled with -fopenmp the inner loops run in parallel.
 * When compiled without it the #pragma directives are silently ignored.
 */
double simulation_step(Road *road);

/*
 * Runs exactly `measure_steps` steps and returns the mean velocity.
 * Use this only for the timed measurement phase, after warmup.
 */
double simulation_measure(Road *road, int measure_steps);

/*
 * Runs warmup steps until the mean velocity stabilises, or until
 * `max_warmup_steps` is reached — whichever comes first.
 *
 * Convergence criterion:
 *   The mean velocity over the last `window_size` steps is compared to
 *   the mean over the previous `window_size` steps. If the absolute
 *   difference is below `convergence_threshold` the system is considered
 *   to have reached steady state.
 *
 * `min_steps` prevents early false positives: convergence is not checked
 * before this many steps have been executed.
 *
 * Returns the number of warmup steps actually executed.
 */
int simulation_warmup_until_steady_state(Road   *road,
                                         int     window_size,
                                         double  convergence_threshold,
                                         int     min_steps,
                                         int     max_warmup_steps);

#endif /* SIMULATION_H */