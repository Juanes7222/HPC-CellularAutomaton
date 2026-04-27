#ifndef SIMULATION_H
#define SIMULATION_H

#include "road.h"

/*
 * Advances the road by one time step and returns the average car
 * velocity for that step (cars that moved / total cars).
 *
 * When compiled with -fopenmp the inner loops run in parallel.
 * When compiled without it the #pragma directives are silently
 * ignored and the function runs sequentially — same source, two modes.
 */
double simulation_step(Road *road);

/*
 * Runs `warmup_steps` steps to reach steady state (not timed),
 * then runs `measure_steps` steps and returns the mean velocity.
 */
double simulation_run(Road *road, int warmup_steps, int measure_steps);

#endif /* SIMULATION_H */