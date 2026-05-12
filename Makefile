# =============================================================================
# Makefile — Traffic Cellular Automaton
#
# Targets:
#   make all          → todos los binarios de producción + tests
#   make seq          → bin/traffic_seq          (serial, sin opt de compilador)
#   make seq_opt      → bin/traffic_seq_opt      (serial, flags optimizadas)
#   make omp          → bin/traffic_omp          (OpenMP, sin opt de compilador)
#   make omp_opt      → bin/traffic_omp_opt      (OpenMP, flags optimizadas)
#   make tests        → bin/traffic_tests        (validador de corrección)
#   make debug        → builds de depuración con sanitizers (seq + omp)
#   make clean        → elimina bin/ y todos los artefactos compilados
#
# Binarios de optimización por compilador (seq_opt / omp_opt)
# -----------------------------------------------------------
# Se compilan desde los mismos fuentes que seq / omp. La única diferencia
# es el conjunto de flags de compilación (CFLAGS_OPT). Esto garantiza que
# cualquier diferencia de rendimiento sea atribuible exclusivamente al
# compilador, no a cambios en el código fuente.
#
# Flags elegidas para este kernel
# --------------------------------
# El loop crítico de simulation.c es 100 % entero/bitwise y memory-bound
# (~3 loads + 1 store por celda). Las flags se seleccionaron con ese perfil:
#
#   -O3                      Habilita vectorización automática, loop
#                            transformations e inlining agresivo.
#   -march=native            Emite AVX2 (o AVX-512 si disponible) para
#                            procesar 8/16 int por instrucción SIMD.
#   -funroll-loops           Reduce el overhead del branch del loop counter;
#                            beneficia especialmente los tamaños L1-bound
#                            (N=8K, N=64K).
#   -flto                    Link-Time Optimization: permite inlinar
#                            compute_next_generation() y
#                            count_departed_cars() directamente en
#                            simulation_step(), eliminando el overhead de
#                            llamada en cada uno de los 1000 steps.
#   -fno-semantic-interposition  Sin esta flag, GCC emite llamadas
#                            indirectas a funciones visibles externamente
#                            para soportar LD_PRELOAD. Con -flto + esta
#                            flag, las funciones internas del TU se inlinan
#                            sin indirección.
#   -falign-loops=32         Alinea el inicio de cada loop a 32 bytes
#                            (un boundary de línea de instrucción AVX2),
#                            evitando que el cuerpo del loop cruce dos
#                            líneas de cache de instrucciones.
#   -fomit-frame-pointer     Libera un registro general adicional para el
#                            allocator. Beneficio marginal en este kernel
#                            pero sin coste observado.
#
#   -ffast-math OMITIDO deliberadamente: el loop crítico no usa punto
#   flotante. avg_velocity es un cálculo de resumen (entero/double en
#   simulation_measure). Incluir -ffast-math podría hacer los resultados
#   de avg_velocity no reproducibles entre compiladores, complicando la
#   validación cruzada del autómata.
#
# _POSIX_C_SOURCE=200809L
# -------------------------
# Expone clock_gettime / CLOCK_MONOTONIC bajo -std=c11. Definido aquí para
# que ningún archivo fuente necesite establecerlo manualmente — las macros
# feature-test pertenecen al tiempo de compilación, no dentro de cabeceras.
#
# -Wno-unknown-pragmas
# ----------------------
# Suprime la advertencia inofensiva que GCC emite cuando el binario serial
# (compilado sin -fopenmp) encuentra las directivas #pragma omp en
# simulation.c. ISO C11 §6.10.6 permite explícitamente ignorar pragmas
# desconocidos, por lo que este es el comportamiento correcto, no un error.
# =============================================================================


CC          = gcc


CFLAGS_BASE = -Wall -Wextra -pedantic -std=c11  \
              -D_POSIX_C_SOURCE=200809L          \
              -Wno-unknown-pragmas


NOOPT_FLAGS = -O0

OPT_FLAGS   = -O3                        \
              -march=native              \
              -funroll-loops             \
              -flto                      \
              -fno-semantic-interposition \
              -falign-loops=32           \
              -fomit-frame-pointer


CFLAGS_SEQ      = $(CFLAGS_BASE) $(NOOPT_FLAGS)
CFLAGS_SEQ_OPT  = $(CFLAGS_BASE) $(OPT_FLAGS)
CFLAGS_OMP      = $(CFLAGS_BASE) $(NOOPT_FLAGS) -fopenmp
CFLAGS_OMP_OPT  = $(CFLAGS_BASE) $(OPT_FLAGS)  -fopenmp

CFLAGS_DBG      = -Wall -Wextra -pedantic -std=c11 -g -O0 \
                  -D_POSIX_C_SOURCE=200809L                \
                  -Wno-unknown-pragmas                     \
                  -fsanitize=address,undefined


LDFLAGS_SEQ = -lm
LDFLAGS_OMP = -fopenmp -lm


INCLUDE     = -Iinclude
SRC_DIR     = src
BIN_DIR     = bin

CORE_SRCS   = $(SRC_DIR)/road.c        \
              $(SRC_DIR)/simulation.c  \
              $(SRC_DIR)/cli_args.c    \
              $(SRC_DIR)/timing.c


BIN_SEQ         = $(BIN_DIR)/traffic_seq
BIN_SEQ_OPT     = $(BIN_DIR)/traffic_seq_opt
BIN_OMP         = $(BIN_DIR)/traffic_omp
BIN_OMP_OPT     = $(BIN_DIR)/traffic_omp_opt
BIN_TESTS       = $(BIN_DIR)/traffic_tests


.PHONY: all seq seq_opt omp omp_opt tests debug clean


all: seq seq_opt omp omp_opt tests


seq: $(BIN_SEQ)

$(BIN_SEQ): $(CORE_SRCS) $(SRC_DIR)/seq_main.c | $(BIN_DIR)
	$(CC) $(CFLAGS_SEQ) $(INCLUDE) $^ -o $@ $(LDFLAGS_SEQ)
	@echo "Built: $@  [serial, no compiler opt]"


seq_opt: $(BIN_SEQ_OPT)

$(BIN_SEQ_OPT): $(CORE_SRCS) $(SRC_DIR)/seq_main.c | $(BIN_DIR)
	$(CC) $(CFLAGS_SEQ_OPT) $(INCLUDE) $^ -o $@ $(LDFLAGS_SEQ)
	@echo "Built: $@  [serial, -O3 -march=native -flto ...]"


omp: $(BIN_OMP)

$(BIN_OMP): $(CORE_SRCS) $(SRC_DIR)/omp_main.c | $(BIN_DIR)
	$(CC) $(CFLAGS_OMP) $(INCLUDE) $^ -o $@ $(LDFLAGS_OMP)
	@echo "Built: $@  [OpenMP, no compiler opt]"


omp_opt: $(BIN_OMP_OPT)

$(BIN_OMP_OPT): $(CORE_SRCS) $(SRC_DIR)/omp_main.c | $(BIN_DIR)
	$(CC) $(CFLAGS_OMP_OPT) $(INCLUDE) $^ -o $@ $(LDFLAGS_OMP)
	@echo "Built: $@  [OpenMP, -O3 -march=native -flto ...]"


tests: $(BIN_TESTS)

$(BIN_TESTS): $(CORE_SRCS) $(SRC_DIR)/validator.c $(SRC_DIR)/validator_main.c | $(BIN_DIR)
	$(CC) $(CFLAGS_OMP_OPT) $(INCLUDE) $^ -o $@ $(LDFLAGS_OMP)
	@echo "Built: $@  [validator, compiled with OPT_FLAGS for speed]"


debug: | $(BIN_DIR)
	$(CC) $(CFLAGS_DBG) $(INCLUDE) $(CORE_SRCS) $(SRC_DIR)/seq_main.c \
	    -o $(BIN_DIR)/traffic_seq_debug $(LDFLAGS_SEQ)
	$(CC) $(CFLAGS_DBG) -fopenmp $(INCLUDE) $(CORE_SRCS) $(SRC_DIR)/omp_main.c \
	    -o $(BIN_DIR)/traffic_omp_debug $(LDFLAGS_OMP)
	@echo "Debug builds ready: traffic_seq_debug  traffic_omp_debug"


$(BIN_DIR):
	mkdir -p $(BIN_DIR)


clean:
	rm -rf $(BIN_DIR)
	@echo "Cleaned."


help:
	@echo ""
	@echo "  make all        → seq  seq_opt  omp  omp_opt  tests"
	@echo "  make seq        → bin/traffic_seq        (serial, -O0)"
	@echo "  make seq_opt    → bin/traffic_seq_opt    (serial, -O3 + flags)"
	@echo "  make omp        → bin/traffic_omp        (OpenMP, -O0)"
	@echo "  make omp_opt    → bin/traffic_omp_opt    (OpenMP, -O3 + flags)"
	@echo "  make tests      → bin/traffic_tests      (validador)"
	@echo "  make debug      → builds con -fsanitize=address,undefined"
	@echo "  make clean      → elimina bin/"
	@echo ""