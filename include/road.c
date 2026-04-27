#include <stdlib.h>
#include <stdio.h>
#include <time.h>
#include "road.h"

static int *allocate_int_array(int length)
{
    int *array = malloc((size_t)length * sizeof(int));
    if (array == NULL)
        fprintf(stderr, "road_create: out of memory allocating %d ints\n", length);
    return array;
}

static void seed_cells_randomly(int *cells, int length, double car_density)
{
    for (int i = 0; i < length; i++) {
        double sample = (double)rand() / ((double)RAND_MAX + 1.0);
        cells[i] = (sample < car_density) ? 1 : 0;
    }
}

static int count_occupied_cells(const int *cells, int length)
{
    int count = 0;
    for (int i = 0; i < length; i++)
        count += cells[i];
    return count;
}

Road *road_create(int length, double car_density)
{
    if (length <= 0 || car_density < 0.0 || car_density > 1.0) {
        fprintf(stderr, "road_create: invalid arguments "
                "(length=%d, density=%.2f)\n", length, car_density);
        return NULL;
    }

    Road *road = malloc(sizeof(Road));
    if (road == NULL) {
        fprintf(stderr, "road_create: out of memory\n");
        return NULL;
    }

    road->length     = length;
    road->cells      = allocate_int_array(length);
    road->next_cells = allocate_int_array(length);

    if (road->cells == NULL || road->next_cells == NULL) {
        free(road->cells);
        free(road->next_cells);
        free(road);
        return NULL;
    }

    srand((unsigned int)time(NULL));
    seed_cells_randomly(road->cells, length, car_density);
    road->car_count = count_occupied_cells(road->cells, length);

    return road;
}

void road_destroy(Road *road)
{
    if (road == NULL) return;
    free(road->cells);
    free(road->next_cells);
    free(road);
}