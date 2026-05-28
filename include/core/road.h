#ifndef ROAD_H
#define ROAD_H

/*
 * Road — state of the one-dimensional traffic cellular automaton.
 *
 * Both `cells` and `next_cells` are pre-allocated at construction time.
 * The simulation swaps these two pointers each step so the inner loop
 * never touches the heap. This is critical for benchmark accuracy: a
 * malloc/free per step would add allocator noise to every timing sample.
 */
typedef struct {
    int *cells;       /* current generation                  */
    int *next_cells;  /* scratch buffer for the next step    */
    int  length;      /* number of cells on the road         */
    int  car_count;   /* conserved quantity — never changes  */
} Road;

/*
 * Allocates a Road of the given length and seeds it randomly so that
 * each cell is occupied with probability `car_density`.
 * Returns NULL on allocation failure or invalid arguments.
 */
Road *road_create(int length, double car_density);

/*
 * Releases all memory owned by the Road. Safe to call with NULL.
 */
void road_destroy(Road *road);

#endif /* ROAD_H */