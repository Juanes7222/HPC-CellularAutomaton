#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include "validator.h"
#include "road.h"
#include "simulation.h"

static void report_test(const char *description, int passed)
{
    printf("  [%s] %s\n", passed ? "PASS" : "FAIL", description);
}

static int test_full_road_produces_zero_velocity(void)
{
    Road *road = road_create(200, 1.0);
    if (road == NULL) return 0;
    double velocity = simulation_step(road);
    road_destroy(road);
    return fabs(velocity) < 1e-9;
}

static int test_single_car_moves_with_velocity_one(void)
{
    Road *road = road_create(100, 0.0);
    if (road == NULL) return 0;
    road->cells[50] = 1;
    road->car_count  = 1;
    double velocity = simulation_step(road);
    road_destroy(road);
    return fabs(velocity - 1.0) < 1e-9;
}

static int test_empty_road_produces_zero_velocity(void)
{
    Road *road = road_create(100, 0.0);
    if (road == NULL) return 0;
    double velocity = simulation_step(road);
    road_destroy(road);
    return fabs(velocity) < 1e-9;
}

static int test_car_count_is_conserved_after_many_steps(void)
{
    const int steps = 100;
    Road *road = road_create(500, 0.4);
    if (road == NULL) return 0;

    int initial_count = road->car_count;
    for (int t = 0; t < steps; t++) {
        simulation_step(road);
        int current_count = 0;
        for (int i = 0; i < road->length; i++)
            current_count += road->cells[i];
        if (current_count != initial_count) {
            road_destroy(road);
            return 0;
        }
    }
    road_destroy(road);
    return 1;
}

static int test_car_at_last_cell_wraps_to_first_cell(void)
{
    Road *road = road_create(20, 0.0);
    if (road == NULL) return 0;
    road->cells[19] = 1;
    road->car_count  = 1;
    simulation_step(road);
    int wrapped_correctly = (road->cells[0] == 1);
    road_destroy(road);
    return wrapped_correctly;
}

int validator_run_all_tests(void)
{
    printf("Running validation tests...\n");
    int all_passed = 1;
    int result;

    result = test_full_road_produces_zero_velocity();
    report_test("full road (density=1.0) -> velocity 0.0", result);
    all_passed &= result;

    result = test_single_car_moves_with_velocity_one();
    report_test("single car on empty road -> velocity 1.0", result);
    all_passed &= result;

    result = test_empty_road_produces_zero_velocity();
    report_test("empty road (density=0.0) -> velocity 0.0", result);
    all_passed &= result;

    result = test_car_count_is_conserved_after_many_steps();
    report_test("car count conserved over 100 steps", result);
    all_passed &= result;

    result = test_car_at_last_cell_wraps_to_first_cell();
    report_test("periodic boundary: last cell wraps to cell 0", result);
    all_passed &= result;

    printf("\n%s\n", all_passed ? "All tests PASSED." : "Some tests FAILED.");
    return all_passed ? 0 : 1;
}