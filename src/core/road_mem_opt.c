/*
 * road_mem_opt.c  --  Memory-optimised road allocation.
 *
 * Optimisations applied
 * ----------------------
 * [MEM-1] uint8_t cell buffers (1 byte/cell vs 4 bytes/cell with int).
 *         Rationale: each cell stores only 0 or 1 — 3 bytes per int are
 *         pure padding that wastes cache capacity and memory bandwidth.
 *
 * [MEM-3] posix_memalign(64) aligns each buffer to a 64-byte boundary.
 *         Rationale:
 *           a) The first cache line of each buffer is never shared with
 *              unrelated heap metadata, avoiding false sharing under OMP.
 *           b) AVX2 256-bit loads (vmovdqu) benefit from 32-byte alignment;
 *              64-byte alignment satisfies both AVX2 and future AVX-512.
 *           c) The hardware stream prefetcher starts a new stream more
 *              reliably from an aligned base address.
 *
 * No other logic is changed relative to road.c — the Road API and
 * road_mem_opt API are intentionally parallel so bench_traffic.sh can
 * run both variants under identical conditions.
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "road_mem_opt.h"

/* 64 bytes = one cache line on all modern x86 / ARM64 targets.         */
#define CACHE_LINE_BYTES 64

/* --------------------------------------------------------------------------
 * Internal helpers
 * -------------------------------------------------------------------------- */

/*
 * allocate_cell_array
 *
 * Allocates `length` uint8_t cells aligned to CACHE_LINE_BYTES.
 * posix_memalign is used instead of malloc to guarantee cache-line
 * alignment of the array base.  Memory returned by posix_memalign is
 * compatible with free().
 *
 * Returns NULL and prints a diagnostic on allocation failure.
 */
static uint8_t *allocate_cell_array(int length)
{
    void   *ptr  = NULL;
    size_t  size = (size_t)length * sizeof(uint8_t);

    if (posix_memalign(&ptr, CACHE_LINE_BYTES, size) != 0) {
        fprintf(stderr,
                "road_mem_opt: posix_memalign(%zu bytes) failed\n", size);
        return NULL;
    }
    return (uint8_t *)ptr;
}

static void seed_cells_randomly(uint8_t *cells, int length, double car_density)
{
    for (int i = 0; i < length; i++) {
        double sample = (double)rand() / ((double)RAND_MAX + 1.0);
        cells[i] = (sample < car_density) ? 1u : 0u;
    }
}

static int count_occupied_cells(const uint8_t *cells, int length)
{
    int count = 0;
    for (int i = 0; i < length; i++)
        count += cells[i];
    return count;
}

/* --------------------------------------------------------------------------
 * Public API
 * -------------------------------------------------------------------------- */

RoadOpt *road_mem_opt_create(int length, double car_density)
{
    if (length <= 0 || car_density < 0.0 || car_density > 1.0) {
        fprintf(stderr,
                "road_mem_opt_create: invalid arguments "
                "(length=%d, density=%.2f)\n", length, car_density);
        return NULL;
    }

    RoadOpt *road = malloc(sizeof(RoadOpt));
    if (road == NULL) {
        fprintf(stderr, "road_mem_opt_create: out of memory\n");
        return NULL;
    }

    road->length     = length;
    road->cells      = allocate_cell_array(length);
    road->next_cells = allocate_cell_array(length);

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

void road_mem_opt_destroy(RoadOpt *road)
{
    if (road == NULL) return;
    free(road->cells);
    free(road->next_cells);
    free(road);
}
