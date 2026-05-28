#ifndef SIMULATION_MEM_OPT_H
#define SIMULATION_MEM_OPT_H

/*
 * simulation_mem_opt.h  --  Memory-optimised simulation for the traffic automaton.
 *
 * Uses RoadOpt (uint8_t buffers, cache-line aligned) instead of Road.
 * The public API is identical to simulation.h so seq_main / omp_main can
 * instantiate either variant by swapping the header and road type.
 */

#include "road_mem_opt.h"

double simulation_mem_opt_step(RoadOpt *road);
double simulation_mem_opt_measure(RoadOpt *road, int measure_steps);
int    simulation_mem_opt_warmup_until_steady_state(RoadOpt *road,
                                                    int      window_size,
                                                    double   convergence_threshold,
                                                    int      min_steps,
                                                    int      max_warmup_steps);

#endif /* SIMULATION_MEM_OPT_H */
