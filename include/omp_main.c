/*
 * omp_main.c — OpenMP entry point for the traffic automaton.
 *
 * Usage:
 *   ./bin/traffic_omp <road_length> <density> <warmup_steps> <measure_steps> <threads>
 *
 * Output (stdout):
 *   A single floating-point number: wall time in milliseconds for the
 *   measure phase only. The warmup phase is excluded from the clock.
 */

#include <stdio.h>
#include <stdlib.h>
#include <omp.h>
#include "road.h"
#include "simulation.h"
#include "cli_args.h"
#include "timing.h"

#define EXPECTED_ARGC 6

static void print_usage(const char *program_name)
{
    fprintf(stderr,
            "Usage: %s <road_length> <density> <warmup_steps> <measure_steps> <threads>\n",
            program_name);
}

int main(int argc, char *argv[])
{
    if (argc != EXPECTED_ARGC) {
        print_usage(argv[0]);
        return EXIT_FAILURE;
    }

    int    road_length   = cli_parse_positive_int(argv[1], "road_length");
    double density       = cli_parse_density(argv[2]);
    int    warmup_steps  = cli_parse_positive_int(argv[3], "warmup_steps");
    int    measure_steps = cli_parse_positive_int(argv[4], "measure_steps");
    int    thread_count  = cli_parse_positive_int(argv[5], "threads");

    omp_set_num_threads(thread_count);

    Road *road = road_create(road_length, density);
    if (road == NULL) return EXIT_FAILURE;

    simulation_run(road, warmup_steps, 0);

    struct timespec clock_start;
    timing_start(&clock_start);

    simulation_run(road, 0, measure_steps);

    double wall_time_ms = timing_elapsed_ms(clock_start);

    road_destroy(road);

    printf("%.3f\n", wall_time_ms);
    return EXIT_SUCCESS;
}