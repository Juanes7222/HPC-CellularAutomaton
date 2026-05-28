# =============================================================================
# Unified Makefile — Traffic Cellular Automaton
#
# Supported implementations:
#   - Serial
#   - OpenMP
#   - MPI
#   - Memory-optimized variants
#   - Validators / tests
#   - Debug builds with sanitizers
#
# Targets:
#   make all          --> all production binaries + validators
#
#   Serial:
#     make seq        --> bin/traffic_seq
#     make seq_opt    --> bin/traffic_seq_opt
#
#   OpenMP:
#     make omp        --> bin/traffic_omp
#     make omp_opt    --> bin/traffic_omp_opt
#
#   MPI:
#     make mpi        --> bin/traffic_mpi
#     make mpi_opt    --> bin/traffic_mpi_opt
#
#   Memory-optimized variants:
#     make seq_mem        --> bin/traffic_seq_mem
#     make seq_mem_opt    --> bin/traffic_seq_mem_opt
#     make omp_mem        --> bin/traffic_omp_mem
#     make omp_mem_opt    --> bin/traffic_omp_mem_opt
#
#   Validators / tests:
#     make tests      --> bin/traffic_tests
#     make validator  --> bin/traffic_validator_mpi
#
#   Debug:
#     make debug      --> debug binaries with AddressSanitizer/UBSan
#
#   Utilities:
#     make clean      --> remove all compiled artifacts
#     make help       --> show build targets and usage
#
# Compiler wrappers
# ------------------
# Serial and OpenMP builds use gcc directly.
#
# MPI builds use mpicc, which is a wrapper around gcc that automatically
# injects the include and linker flags required by the installed MPI runtime
# (OpenMPI, MPICH, etc.). Optimization flags are still forwarded directly
# to the underlying compiler backend.
#
# Optimization philosophy
# ------------------------
# The simulation kernel is primarily integer/bitwise and memory-bound
# (~3 loads + 1 store per cell). The optimization flags are selected
# specifically for that workload profile:
#
#   -O3                      Enables aggressive optimization, vectorization,
#                            loop transformations and inlining.
#
#   -march=native            Emits architecture-specific SIMD instructions
#                            (AVX2 / AVX-512 when available).
#
#   -funroll-loops           Reduces loop branch overhead for tight kernels.
#
#   -flto                    Enables Link-Time Optimization and cross-TU
#                            inlining.
#
#   -fno-semantic-interposition
#                            Allows more aggressive inlining by removing
#                            externally visible indirections.
#
#   -falign-loops=32         Aligns hot loops to AVX instruction boundaries.
#
#   -fomit-frame-pointer     Frees one additional general-purpose register.
#
#   -ffast-math deliberately omitted:
#   Floating-point arithmetic is only used for summary statistics
#   (avg_velocity). Enabling fast-math could make results non-reproducible
#   across implementations and compilers.
#
# POSIX feature macros
# ---------------------
#   _POSIX_C_SOURCE=200809L
#     Used for serial/OpenMP builds to expose clock_gettime.
#
#   _POSIX_C_SOURCE=200112L
#     Used for MPI builds to expose posix_memalign.
#     MPI_Wtime replaces clock_gettime in distributed execution.
#
# OpenMP note
# -------------
# OpenMP builds are enabled through -fopenmp. The same simulation core
# is reused for both serial and threaded execution, allowing direct
# compiler/runtime comparisons without modifying the computational kernel.
#
# Sanitizers
# -----------
# Debug builds use:
#
#   -fsanitize=address
#   -fsanitize=undefined
#
# to detect:
#   - out-of-bounds accesses
#   - use-after-free
#   - undefined behavior
#   - integer issues
#
# OpenMPI may report internal allocations as memory leaks under ASan.
# These are known runtime false positives. To suppress them:
#
#   export ASAN_OPTIONS=detect_leaks=0
#
# before executing mpirun.
# =============================================================================


CC       = gcc
MPICC    = mpicc

CFLAGS_BASE = -Wall -Wextra -pedantic -std=c11 \
              -Wno-unknown-pragmas

NOOPT_FLAGS = -O0

OPT_FLAGS   = -O3                         \
              -march=native               \
              -funroll-loops              \
              -flto                       \
              -fno-semantic-interposition \
              -falign-loops=32            \
              -fomit-frame-pointer

POSIX_SEQ_OMP = -D_POSIX_C_SOURCE=200809L
POSIX_MPI     = -D_POSIX_C_SOURCE=200112L

CFLAGS_SEQ      = $(CFLAGS_BASE) $(POSIX_SEQ_OMP) $(NOOPT_FLAGS)
CFLAGS_SEQ_OPT  = $(CFLAGS_BASE) $(POSIX_SEQ_OMP) $(OPT_FLAGS)

CFLAGS_OMP      = $(CFLAGS_BASE) $(POSIX_SEQ_OMP) $(NOOPT_FLAGS) -fopenmp
CFLAGS_OMP_OPT  = $(CFLAGS_BASE) $(POSIX_SEQ_OMP) $(OPT_FLAGS)  -fopenmp

CFLAGS_MPI      = $(CFLAGS_BASE) $(POSIX_MPI) $(NOOPT_FLAGS)
CFLAGS_MPI_OPT  = $(CFLAGS_BASE) $(POSIX_MPI) $(OPT_FLAGS)

CFLAGS_DBG      = -Wall -Wextra -pedantic -std=c11 -g -O0 \
                  -fsanitize=address,undefined

LDFLAGS_SEQ = -lm
LDFLAGS_OMP = -fopenmp -lm
LDFLAGS_MPI = -lm

BIN_DIR = bin

CORE_DIR = src/core
SEQ_DIR  = src/seq
OMP_DIR  = src/omp
MPI_DIR  = src/mpi

INCLUDE_CORE = -Iinclude/core
INCLUDE_MPI  = -Iinclude/mpi

CORE_SRCS = $(CORE_DIR)/road.c        \
            $(CORE_DIR)/simulation.c   \
            $(CORE_DIR)/cli_args.c     \
            $(CORE_DIR)/timing.c

CORE_MEM_SRCS = $(CORE_DIR)/road_mem_opt.c        \
                $(CORE_DIR)/simulation_mem_opt.c  \
                $(CORE_DIR)/cli_args.c            \
                $(CORE_DIR)/timing.c

MPI_SRCS = $(MPI_DIR)/road_mpi.c       \
           $(MPI_DIR)/simulation_mpi.c

BIN_SEQ         = $(BIN_DIR)/traffic_seq
BIN_SEQ_OPT     = $(BIN_DIR)/traffic_seq_opt

BIN_OMP         = $(BIN_DIR)/traffic_omp
BIN_OMP_OPT     = $(BIN_DIR)/traffic_omp_opt

BIN_MPI         = $(BIN_DIR)/traffic_mpi
BIN_MPI_OPT     = $(BIN_DIR)/traffic_mpi_opt

BIN_SEQ_MEM     = $(BIN_DIR)/traffic_seq_mem
BIN_SEQ_MEM_OPT = $(BIN_DIR)/traffic_seq_mem_opt

BIN_OMP_MEM     = $(BIN_DIR)/traffic_omp_mem
BIN_OMP_MEM_OPT = $(BIN_DIR)/traffic_omp_mem_opt

BIN_TESTS       = $(BIN_DIR)/traffic_tests
BIN_VALIDATOR   = $(BIN_DIR)/traffic_validator_mpi

.PHONY: all clean help \
        seq seq_opt omp omp_opt mpi mpi_opt \
        seq_mem seq_mem_opt omp_mem omp_mem_opt \
        tests validator debug

all: seq seq_opt omp omp_opt mpi mpi_opt \
     seq_mem seq_mem_opt omp_mem omp_mem_opt \
     tests validator

seq: $(BIN_SEQ)

$(BIN_SEQ): $(CORE_SRCS) $(SEQ_DIR)/seq_main.c | $(BIN_DIR)
	$(CC) $(CFLAGS_SEQ) $(INCLUDE_CORE) $^ -o $@ $(LDFLAGS_SEQ)

seq_opt: $(BIN_SEQ_OPT)

$(BIN_SEQ_OPT): $(CORE_SRCS) $(SEQ_DIR)/seq_main.c | $(BIN_DIR)
	$(CC) $(CFLAGS_SEQ_OPT) $(INCLUDE_CORE) $^ -o $@ $(LDFLAGS_SEQ)

omp: $(BIN_OMP)

$(BIN_OMP): $(CORE_SRCS) $(OMP_DIR)/omp_main.c | $(BIN_DIR)
	$(CC) $(CFLAGS_OMP) $(INCLUDE_CORE) $^ -o $@ $(LDFLAGS_OMP)

omp_opt: $(BIN_OMP_OPT)

$(BIN_OMP_OPT): $(CORE_SRCS) $(OMP_DIR)/omp_main.c | $(BIN_DIR)
	$(CC) $(CFLAGS_OMP_OPT) $(INCLUDE_CORE) $^ -o $@ $(LDFLAGS_OMP)

mpi: $(BIN_MPI)

$(BIN_MPI): $(MPI_SRCS) $(MPI_DIR)/mpi_main.c | $(BIN_DIR)
	$(MPICC) $(CFLAGS_MPI) $(INCLUDE_CORE) $(INCLUDE_MPI) $^ -o $@ $(LDFLAGS_MPI)

mpi_opt: $(BIN_MPI_OPT)

$(BIN_MPI_OPT): $(MPI_SRCS) $(MPI_DIR)/mpi_main.c | $(BIN_DIR)
	$(MPICC) $(CFLAGS_MPI_OPT) $(INCLUDE_CORE) $(INCLUDE_MPI) $^ -o $@ $(LDFLAGS_MPI)

seq_mem: $(BIN_SEQ_MEM)

$(BIN_SEQ_MEM): $(CORE_MEM_SRCS) $(SEQ_DIR)/seq_main_mem_opt.c | $(BIN_DIR)
	$(CC) $(CFLAGS_SEQ) $(INCLUDE_CORE) $^ -o $@ $(LDFLAGS_SEQ)

seq_mem_opt: $(BIN_SEQ_MEM_OPT)

$(BIN_SEQ_MEM_OPT): $(CORE_MEM_SRCS) $(SEQ_DIR)/seq_main_mem_opt.c | $(BIN_DIR)
	$(CC) $(CFLAGS_SEQ_OPT) $(INCLUDE_CORE) $^ -o $@ $(LDFLAGS_SEQ)

omp_mem: $(BIN_OMP_MEM)

$(BIN_OMP_MEM): $(CORE_MEM_SRCS) $(OMP_DIR)/omp_main_mem_opt.c | $(BIN_DIR)
	$(CC) $(CFLAGS_OMP) $(INCLUDE_CORE) $^ -o $@ $(LDFLAGS_OMP)

omp_mem_opt: $(BIN_OMP_MEM_OPT)

$(BIN_OMP_MEM_OPT): $(CORE_MEM_SRCS) $(OMP_DIR)/omp_main_mem_opt.c | $(BIN_DIR)
	$(CC) $(CFLAGS_OMP_OPT) $(INCLUDE_CORE) $^ -o $@ $(LDFLAGS_OMP)

tests: $(BIN_TESTS)

$(BIN_TESTS): $(CORE_SRCS) $(CORE_DIR)/validator.c $(CORE_DIR)/validator_main.c | $(BIN_DIR)
	$(CC) $(CFLAGS_SEQ_OPT) $(INCLUDE_CORE) $^ -o $@ $(LDFLAGS_SEQ)

validator: $(BIN_VALIDATOR)

$(BIN_VALIDATOR): $(MPI_SRCS) $(MPI_DIR)/validator_mpi.c $(MPI_DIR)/validator_mpi_main.c | $(BIN_DIR)
	$(MPICC) $(CFLAGS_MPI_OPT) $(INCLUDE_CORE) $(INCLUDE_MPI) $^ -o $@ $(LDFLAGS_MPI)

debug: | $(BIN_DIR)
	$(CC) $(CFLAGS_DBG) $(INCLUDE_CORE) $(CORE_SRCS) $(SEQ_DIR)/seq_main.c -o $(BIN_DIR)/traffic_seq_debug $(LDFLAGS_SEQ)
	$(CC) $(CFLAGS_DBG) -fopenmp $(INCLUDE_CORE) $(CORE_SRCS) $(OMP_DIR)/omp_main.c -o $(BIN_DIR)/traffic_omp_debug $(LDFLAGS_OMP)
	$(MPICC) $(CFLAGS_DBG) $(INCLUDE_CORE) $(INCLUDE_MPI) $(MPI_SRCS) $(MPI_DIR)/mpi_main.c -o $(BIN_DIR)/traffic_mpi_debug $(LDFLAGS_MPI)

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

clean:
	rm -rf $(BIN_DIR)

help:
	@echo ""
	@echo "  make all          --> seq seq_opt omp omp_opt mpi mpi_opt seq_mem seq_mem_opt omp_mem omp_mem_opt tests validator"
	@echo "  make seq          --> bin/traffic_seq              (serial, -O0)"
	@echo "  make seq_opt      --> bin/traffic_seq_opt          (serial, -O3 + flags)"
	@echo "  make omp          --> bin/traffic_omp              (OpenMP, -O0)"
	@echo "  make omp_opt      --> bin/traffic_omp_opt          (OpenMP, -O3 + flags)"
	@echo "  make mpi          --> bin/traffic_mpi              (MPI, -O0)"
	@echo "  make mpi_opt      --> bin/traffic_mpi_opt          (MPI, -O3 + flags)"
	@echo "  make seq_mem      --> bin/traffic_seq_mem          (serial, memory-optimized)"
	@echo "  make seq_mem_opt  --> bin/traffic_seq_mem_opt      (serial, memory-optimized + flags)"
	@echo "  make omp_mem      --> bin/traffic_omp_mem          (OpenMP, memory-optimized)"
	@echo "  make omp_mem_opt  --> bin/traffic_omp_mem_opt      (OpenMP, memory-optimized + flags)"
	@echo "  make tests        --> bin/traffic_tests            (correctness validator)"
	@echo "  make validator    --> bin/traffic_validator_mpi    (MPI validator)"
	@echo "  make debug        --> bin/traffic_seq_debug, bin/traffic_omp_debug, bin/traffic_mpi_debug"
	@echo "  make clean        --> removes bin/"
	@echo ""
	@echo "  Usage:"
	@echo "    mpirun -np <P> bin/traffic_mpi_opt <N> <density> <max_warmup> <measure_steps>"
	@echo "    mpirun -np <P> bin/traffic_validator_mpi"
	@echo ""