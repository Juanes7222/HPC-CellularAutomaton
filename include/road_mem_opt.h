#ifndef ROAD_MEM_OPT_H
#define ROAD_MEM_OPT_H

/*
 * road_mem_opt.h  --  Memory-optimised road structure for the traffic automaton.
 *
 * Key differences vs road.h
 * -------------------------
 * [MEM-1] Cell buffers use uint8_t instead of int.
 *         Working set: 2 × N × 1 B  (vs 2 × N × 4 B with int).
 *         A 64-byte cache line now holds 64 cells (vs 16).
 *         At N=2M this drops the working set from 16 MB to 4 MB,
 *         keeping it inside L3 instead of spilling to DRAM.
 *
 * [MEM-3] Buffers are allocated with posix_memalign(64) so each array
 *         starts on a 64-byte (cache line) boundary.
 *         This eliminates false sharing on the first and last cache
 *         line under OpenMP and lets the hardware prefetcher begin
 *         on an aligned address.
 *
 * road_mem_opt_create / road_mem_opt_destroy mirror the road_create /
 * road_destroy API so both variants can coexist in the same binary.
 */

#include <stdint.h>

typedef struct {
    uint8_t *cells;       /* current generation — 1 byte per cell */
    uint8_t *next_cells;  /* next    generation — 1 byte per cell */
    int      length;
    int      car_count;
} RoadOpt;

RoadOpt *road_mem_opt_create(int length, double car_density);
void     road_mem_opt_destroy(RoadOpt *road);

#endif /* ROAD_MEM_OPT_H */
