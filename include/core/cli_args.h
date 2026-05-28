#ifndef CLI_ARGS_H
#define CLI_ARGS_H

/*
 * cli_args.h
 *
 * Minimal argument-parsing helpers shared by seq_main.c and omp_main.c.
 * Keeping this separate avoids duplicating error handling across both
 * entry points and makes each main() trivial to read.
 */

/*
 * Parses a positive integer from `str`.
 * Prints an error referencing `param_name` and exits on failure.
 */
int    cli_parse_positive_int(const char *str, const char *param_name);

/*
 * Parses a floating-point density value in [0.0, 1.0] from `str`.
 * Prints an error and exits on failure.
 */
double cli_parse_density(const char *str);

#endif /* CLI_ARGS_H */