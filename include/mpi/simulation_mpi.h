#ifndef SIMULATION_MPI_H
#define SIMULATION_MPI_H

#include "road_mpi.h"

/*
 * Advances the automaton by one step and returns the global average velocity
 * for that step (departed cars / total cars).
 */
double simulation_mpi_step(RoadMPI *road);

/*
 * Runs measure_steps iterations after steady state and returns the time-averaged
 * velocity across all steps.
 */
double simulation_mpi_measure(RoadMPI *road, int measure_steps);

/*
 * Runs up to max_warmup_steps iterations. Declares convergence when the range
 * (max - min) of the last window_size velocity samples falls below
 * convergence_threshold, provided at least min_steps have elapsed.
 * Returns the number of warmup steps actually executed.
 */
int simulation_mpi_warmup_until_steady_state(RoadMPI *road,
                                             int window_size,
                                             double convergence_threshold,
                                             int min_steps,
                                             int max_warmup_steps);

#endif /* SIMULATION_MPI_H */
