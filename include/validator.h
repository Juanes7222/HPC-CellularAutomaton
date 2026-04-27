#ifndef VALIDATOR_H
#define VALIDATOR_H

/*
 * Runs all built-in correctness tests. Each test verifies a property
 * whose expected value is analytically known.
 *
 * Prints PASS/FAIL for each test to stdout.
 * Returns 0 if all tests pass, 1 otherwise.
 */
int validator_run_all_tests(void);

#endif /* VALIDATOR_H */