#ifndef VALIDATOR_MPI_H
#define VALIDATOR_MPI_H

/*
 * Runs all semantic validation tests on the distributed automaton.
 * Must be called collectively on all processes.
 * Returns 1 if every test passes, 0 otherwise.
 * Diagnostic output goes to stderr from rank 0 only.
 */
int validator_mpi_run_all_tests(void);

#endif /* VALIDATOR_MPI_H */
