#include <stdlib.h>
#include <stdio.h>
#include "cli_args.h"

int cli_parse_positive_int(const char *str, const char *param_name)
{
    char *end;
    long value = strtol(str, &end, 10);
    if (*end != '\0' || value <= 0) {
        fprintf(stderr, "Invalid %s: '%s' (expected a positive integer)\n",
                param_name, str);
        exit(EXIT_FAILURE);
    }
    return (int)value;
}

double cli_parse_density(const char *str)
{
    char *end;
    double value = strtod(str, &end);
    if (*end != '\0' || value < 0.0 || value > 1.0) {
        fprintf(stderr,
                "Invalid density: '%s' (expected a value in [0.0, 1.0])\n", str);
        exit(EXIT_FAILURE);
    }
    return value;
}