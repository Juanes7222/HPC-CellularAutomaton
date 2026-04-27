#include <stdlib.h>
#include "validator.h"

int main(void)
{
    int failed = validator_run_all_tests();
    return failed ? EXIT_FAILURE : EXIT_SUCCESS;
}