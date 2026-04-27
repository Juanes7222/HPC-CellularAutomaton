# =============================================================================
# Makefile — Traffic Cellular Automaton
#
# Targets:
#   make all      → bin/traffic_seq  bin/traffic_omp  bin/traffic_tests
#   make seq      → bin/traffic_seq   (serial baseline, no OpenMP)
#   make omp      → bin/traffic_omp   (OpenMP, threads via argv)
#   make tests    → bin/traffic_tests (correctness validator)
#   make debug    → debug builds of seq and omp with sanitisers
#   make clean    → remove bin/ and all compiled artefacts
# =============================================================================

CC          = gcc

# _POSIX_C_SOURCE=200809L exposes clock_gettime / CLOCK_MONOTONIC under -std=c11.
# Defined here so no source file needs to set it manually — feature-test macros
# belong at compile time, not inside headers.
#
# -Wno-unknown-pragmas suppresses the harmless warning that GCC emits when the
# sequential binary (compiled without -fopenmp) encounters the #pragma omp
# directives in simulation.c. ISO C11 §6.10.6 explicitly permits ignoring
# unknown pragmas, so this is correct behaviour, not a bug.
CFLAGS_BASE = -Wall -Wextra -pedantic -std=c11 -O2 \
              -D_POSIX_C_SOURCE=200809L             \
              -Wno-unknown-pragmas

CFLAGS_SEQ  = $(CFLAGS_BASE)
CFLAGS_OMP  = $(CFLAGS_BASE) -fopenmp
CFLAGS_DBG  = -Wall -Wextra -pedantic -std=c11 -g  \
              -D_POSIX_C_SOURCE=200809L             \
              -Wno-unknown-pragmas                  \
              -fsanitize=address,undefined

INCLUDE     = -Iinclude
LDFLAGS_SEQ = -lm
LDFLAGS_OMP = -fopenmp -lm

SRC_DIR     = src
BIN_DIR     = bin

CORE_SRCS   = $(SRC_DIR)/road.c        \
              $(SRC_DIR)/simulation.c  \
              $(SRC_DIR)/cli_args.c    \
              $(SRC_DIR)/timing.c

BIN_SEQ     = $(BIN_DIR)/traffic_seq
BIN_OMP     = $(BIN_DIR)/traffic_omp
BIN_TESTS   = $(BIN_DIR)/traffic_tests

.PHONY: all seq omp tests debug clean

all: seq omp tests

seq: $(BIN_SEQ)

$(BIN_SEQ): $(CORE_SRCS) $(SRC_DIR)/seq_main.c | $(BIN_DIR)
	$(CC) $(CFLAGS_SEQ) $(INCLUDE) $^ -o $@ $(LDFLAGS_SEQ)
	@echo "Built: $@"

omp: $(BIN_OMP)

$(BIN_OMP): $(CORE_SRCS) $(SRC_DIR)/omp_main.c | $(BIN_DIR)
	$(CC) $(CFLAGS_OMP) $(INCLUDE) $^ -o $@ $(LDFLAGS_OMP)
	@echo "Built: $@"

tests: $(BIN_TESTS)

$(BIN_TESTS): $(CORE_SRCS) $(SRC_DIR)/validator.c $(SRC_DIR)/validator_main.c | $(BIN_DIR)
	$(CC) $(CFLAGS_OMP) $(INCLUDE) $^ -o $@ $(LDFLAGS_OMP)
	@echo "Built: $@"

debug: | $(BIN_DIR)
	$(CC) $(CFLAGS_DBG) $(INCLUDE) $(CORE_SRCS) $(SRC_DIR)/seq_main.c \
	    -o $(BIN_DIR)/traffic_seq_debug $(LDFLAGS_SEQ)
	$(CC) $(CFLAGS_DBG) -fopenmp $(INCLUDE) $(CORE_SRCS) $(SRC_DIR)/omp_main.c \
	    -o $(BIN_DIR)/traffic_omp_debug $(LDFLAGS_OMP)
	@echo "Debug builds ready."

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

clean:
	rm -rf $(BIN_DIR)