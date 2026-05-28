#ifndef MPI_COMMON_H
#define MPI_COMMON_H

/* Message tags: named after the direction of travel of the boundary cell. */
#define TAG_SEND_LEFT   100
#define TAG_SEND_RIGHT  101

static inline int left_rank(int rank, int size) {
    return (rank - 1 + size) % size;
}

static inline int right_rank(int rank, int size) {
    return (rank + 1) % size;
}

#endif /* MPI_COMMON_H */
