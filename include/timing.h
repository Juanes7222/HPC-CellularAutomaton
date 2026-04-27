#ifndef TIMING_H
#define TIMING_H

#include <time.h>

/*
 * timing.h
 *
 * Thin wrapper around CLOCK_MONOTONIC. Centralising the clock call in
 * one module avoids repeating struct timespec boilerplate in every main.
 *
 * Requires _POSIX_C_SOURCE >= 200809L — provided globally via CFLAGS
 * in the Makefile so no source file needs to set it manually.
 */

void   timing_start(struct timespec *out_start);
double timing_elapsed_ms(struct timespec start);

#endif /* TIMING_H */