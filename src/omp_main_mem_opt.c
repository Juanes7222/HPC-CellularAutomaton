/*
 * omp_main_mem_opt.c  --  OpenMP entry point for the memory-optimised variant.
 *
 * Identical CLI contract to omp_main.c:
 *   ./bin/traffic_omp_mem_opt <road_length> <density> <max_warmup> <measure_steps> <threads>
 */

#include <stdio.h>
#include <stdlib.h>
#include <omp.h>

#include "road_mem_opt.h"
#include "simulation_mem_opt.h"
#include "cli_args.h"
#include "timing.h"

#define EXPECTED_ARGC               6
#define WARMUP_WINDOW_SIZE          50
#define WARMUP_CONVERGENCE_THRESHOLD 1e-4
#define WARMUP_MIN_STEPS            200

static void print_usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s <road_length> <density> "
            "<max_warmup_steps> <measure_steps> <threads>\n", prog);
}

static void log_warmup_result(int steps_done, int max_warmup_steps)
{
    if (steps_done < max_warmup_steps)
        fprintf(stderr, "[warmup] converged after %d steps\n", steps_done);
    else
        fprintf(stderr, "[warmup] hit ceiling at %d steps (did not converge)\n",
                steps_done);
}

int main(int argc, char *argv[])
{
    if (argc != EXPECTED_ARGC) {
        print_usage(argv[0]);
        return EXIT_FAILURE;
    }

    int    road_length      = cli_parse_positive_int(argv[1], "road_length");
    double density          = cli_parse_density(argv[2]);
    int    max_warmup_steps = cli_parse_positive_int(argv[3], "max_warmup_steps");
    int    measure_steps    = cli_parse_positive_int(argv[4], "measure_steps");
    int    thread_count     = cli_parse_positive_int(argv[5], "threads");

    omp_set_num_threads(thread_count);
    fprintf(stderr, "[omp_mem_opt] threads requested: %d  active: %d\n",
            thread_count, omp_get_max_threads());

    RoadOpt *road = road_mem_opt_create(road_length, density);
    if (road == NULL) return EXIT_FAILURE;

    int warmup_done = simulation_mem_opt_warmup_until_steady_state(
        road,
        WARMUP_WINDOW_SIZE,
        WARMUP_CONVERGENCE_THRESHOLD,
        WARMUP_MIN_STEPS,
        max_warmup_steps);
    log_warmup_result(warmup_done, max_warmup_steps);

    struct timespec clock_start;
    timing_start(&clock_start);

    double avg_velocity = simulation_mem_opt_measure(road, measure_steps);

    double wall_time_ms = timing_elapsed_ms(clock_start);

    road_mem_opt_destroy(road);

    printf("%.3f %.6f\n", wall_time_ms, avg_velocity);
    return EXIT_SUCCESS;
}
