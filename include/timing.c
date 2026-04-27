#include <time.h>
#include "timing.h"

void timing_start(struct timespec *out_start)
{
    clock_gettime(CLOCK_MONOTONIC, out_start);
}

double timing_elapsed_ms(struct timespec start)
{
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);

    double delta_ns = (double)(now.tv_sec  - start.tv_sec)  * 1e9
                    + (double)(now.tv_nsec - start.tv_nsec);
    return delta_ns / 1e6;
}