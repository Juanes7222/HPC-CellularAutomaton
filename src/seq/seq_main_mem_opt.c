/*
 * seq_main_mem_opt.c  --  Sequential entry point for the memory-optimised variant.
 *
 * Identical CLI contract to seq_main.c:
 *   ./bin/traffic_seq_mem_opt <road_length> <density> <max_warmup> <measure_steps>
 *
 * The only difference is that it instantiates RoadOpt (uint8_t, aligned)
 * instead of Road (int, malloc) and calls simulation_mem_opt_* functions.
 */

#include <stdio.h>
#include <stdlib.h>

#include "road_mem_opt.h"
#include "simulation_mem_opt.h"
#include "cli_args.h"
#include "timing.h"

#define EXPECTED_ARGC               5
#define WARMUP_WINDOW_SIZE          50
#define WARMUP_CONVERGENCE_THRESHOLD 1e-4
#define WARMUP_MIN_STEPS            200

static void print_usage(const char *prog)
{
    fprintf(stderr,
            "Usage: %s <road_length> <density> "
            "<max_warmup_steps> <measure_steps>\n", prog);
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
