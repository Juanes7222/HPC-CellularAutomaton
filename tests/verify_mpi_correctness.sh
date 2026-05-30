#!/usr/bin/env bash
# =============================================================================
# verify_mpi_correctness.sh
#
# Verifies the correctness of the MPI cellular automaton implementation.
# Does NOT measure performance — use bench_traffic_mpi.sh for that.
#
# The script locates the project root automatically, so it can be invoked
# from any directory (project root, tests/, or any subdirectory):
#
#   bash tests/verify_mpi_correctness.sh
#   bash verify_mpi_correctness.sh          # from project root
#   cd tests && bash verify_mpi_correctness.sh
#
# Test plan
# ----------
#   1. Build        make tests validator mpi_opt seq_mem_opt
#   2. Baseline     bin/traffic_tests passes (serial correctness)
#   3. Validator    bin/traffic_validator_mpi passes with np=1, 2, 4
#   4. Boundaries   density=0.0 and density=1.0 must yield velocity=0.0
#                   for np=1, 2, 4 (deterministic, no seed dependency)
#   5. Ranges       expected velocity intervals for low/high densities
#   6. Consistency  np=1, 2, 4 all produce valid output for density=0.5
#   7. Format       output of mpi_opt matches "TIME VEL" contract of seq
#
# Usage
#   bash verify_mpi_correctness.sh [--np-max N] [--no-build]
#   bash verify_mpi_correctness.sh --help
#
# Exit codes
#   0  all tests passed
#   1  one or more tests failed
#   2  prerequisites missing or build failed
# =============================================================================

set -uo pipefail

# --------------------------------------------------------------------------- #
# Locate project root (Makefile is the anchor)                               #
# --------------------------------------------------------------------------- #

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Walk up from the script location until we find the Makefile.
PROJECT_ROOT="${SCRIPT_DIR}"
while [[ "${PROJECT_ROOT}" != "/" && ! -f "${PROJECT_ROOT}/Makefile" ]]; do
    PROJECT_ROOT="$(dirname "${PROJECT_ROOT}")"
done

if [[ ! -f "${PROJECT_ROOT}/Makefile" ]]; then
    echo "error: could not locate Makefile from '${SCRIPT_DIR}'" >&2
    exit 2
fi

cd "${PROJECT_ROOT}"

# --------------------------------------------------------------------------- #
# Configuration                                                               #
# --------------------------------------------------------------------------- #

BIN_DIR="bin"
MPIRUN="${MPIRUN:-mpirun}"
MAKE="${MAKE:-make}"

# Road length for boundary and range tests.
N=10000
MAX_WARMUP=1000
MEASURE_STEPS=300

# Convergence tolerance for "velocity must be zero" checks.
ZERO_TOL="0.001"

# Expected velocity ranges (Nagel-Schreckenberg vmax=1 model):
#   density=0.05  →  velocity in [0.85, 1.00]
#   density=0.95  →  velocity in [0.00, 0.12]
LOW_DENSITY="0.05"
LOW_VEL_MIN="0.85"
LOW_VEL_MAX="1.00"

HIGH_DENSITY="0.95"
HIGH_VEL_MIN="0.00"
HIGH_VEL_MAX="0.12"

# Maximum np to test. Capped at available cores and at 4 for the validator
# (its smallest test road has N=4 cells, so np=4 is the safe upper bound).
MAX_NP_USER=4
MAX_NP_VALIDATOR=4

# --------------------------------------------------------------------------- #
# Argument parsing                                                            #
# --------------------------------------------------------------------------- #

NO_BUILD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --no-build)
            NO_BUILD=1
            ;;
        --np-max)
            shift
            MAX_NP_USER="${1:?--np-max requires a value}"
            ;;
        --np-max=*)
            MAX_NP_USER="${1#*=}"
            ;;
        *)
            echo "error: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
    shift
done

# --------------------------------------------------------------------------- #
# Terminal output                                                             #
# --------------------------------------------------------------------------- #

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

PASS_COUNT=0
FAIL_COUNT=0

section() {
    echo ""
    echo -e "${CYAN}${BOLD}==> $1${NC}"
}

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "  ${GREEN}[PASS]${NC} $1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "  ${RED}[FAIL]${NC} $1"
    if [[ -n "${2:-}" ]]; then
        echo -e "         ${YELLOW}$2${NC}"
    fi
}

info() {
    echo -e "  ${YELLOW}[INFO]${NC} $1"
}

# --------------------------------------------------------------------------- #
# Helpers                                                                     #
# --------------------------------------------------------------------------- #

mpi_run() {
    local np="$1"; shift
    "${MPIRUN}" --oversubscribe -np "$np" "$@"
}

parse_velocity() { echo "$1" | awk 'NR==1 {print $2}'; }
parse_time()     { echo "$1" | awk 'NR==1 {print $1}'; }

check_float_in_range() {
    local val="$1" lo="$2" hi="$3" desc="$4"
    if awk "BEGIN { exit !($val >= $lo && $val <= $hi) }"; then
        pass "$desc  (got $val, expected [$lo, $hi])"
    else
        fail "$desc  (got $val, expected [$lo, $hi])"
    fi
}

check_float_near_zero() {
    local val="$1" desc="$2"
    if awk "BEGIN { exit !($val >= 0.0 && $val < $ZERO_TOL) }"; then
        pass "$desc  (got $val ≈ 0)"
    else
        fail "$desc  (got $val, expected < $ZERO_TOL)"
    fi
}

check_output_format() {
    local output="$1" desc="$2"
    local fields
    fields=$(echo "$output" | awk 'NR==1 {print NF}')
    if [[ "$fields" == "2" ]]; then
        pass "$desc  (format: two fields)"
    else
        fail "$desc  (expected 2 fields, got ${fields:-0})"
    fi
}

# --------------------------------------------------------------------------- #
# 0. Prerequisites                                                            #
# --------------------------------------------------------------------------- #

section "Prerequisites"

info "project root: ${PROJECT_ROOT}"

PREREQ_OK=1
for cmd in "${MAKE}" "${MPIRUN}" awk nproc; do
    if command -v "$cmd" &>/dev/null; then
        pass "$cmd found  ($(command -v "$cmd"))"
    else
        fail "$cmd not found"
        PREREQ_OK=0
    fi
done

if [[ "$PREREQ_OK" -eq 0 ]]; then
    echo ""
    echo -e "${RED}Missing prerequisites. Aborting.${NC}"
    exit 2
fi

AVAIL_CORES=$(nproc)
NP_MAX=$(( MAX_NP_USER < AVAIL_CORES ? MAX_NP_USER : AVAIL_CORES ))
NP_MAX=$(( NP_MAX < 1 ? 1 : NP_MAX ))
NP_VALIDATOR=$(( MAX_NP_VALIDATOR < NP_MAX ? MAX_NP_VALIDATOR : NP_MAX ))

info "available cores: ${AVAIL_CORES}  →  np ceiling: ${NP_MAX}"

# --------------------------------------------------------------------------- #
# 1. Build                                                                    #
# --------------------------------------------------------------------------- #

section "Build"

if [[ "$NO_BUILD" -eq 1 ]]; then
    info "--no-build: skipping compilation"
else
    BUILD_TARGETS="tests validator mpi_opt seq_mem_opt"
    info "running: ${MAKE} ${BUILD_TARGETS}  (from ${PROJECT_ROOT})"

    BUILD_LOG=$(mktemp)
    if ${MAKE} ${BUILD_TARGETS} > "${BUILD_LOG}" 2>&1; then
        pass "make ${BUILD_TARGETS}"
    else
        fail "make ${BUILD_TARGETS}"
        echo ""
        tail -30 "${BUILD_LOG}" | sed 's/^/         /'
        rm -f "${BUILD_LOG}"
        exit 2
    fi
    rm -f "${BUILD_LOG}"
fi

MISSING=0
for bin in "${BIN_DIR}/traffic_tests" \
           "${BIN_DIR}/traffic_validator_mpi" \
           "${BIN_DIR}/traffic_mpi_opt" \
           "${BIN_DIR}/traffic_seq_mem_opt"; do
    if [[ -x "$bin" ]]; then
        pass "$bin exists and is executable"
    else
        fail "$bin missing or not executable"
        MISSING=1
    fi
done

if [[ "$MISSING" -eq 1 ]]; then
    echo ""
    echo -e "${RED}Required binaries missing. Aborting.${NC}"
    exit 2
fi

# --------------------------------------------------------------------------- #
# 2. Serial correctness baseline                                              #
# --------------------------------------------------------------------------- #

section "Serial correctness baseline  (bin/traffic_tests)"

if "${BIN_DIR}/traffic_tests" 2>/dev/null; then
    pass "traffic_tests exited 0"
else
    fail "traffic_tests failed  (run it manually for details)"
fi

# --------------------------------------------------------------------------- #
# 3. MPI unit validator                                                       #
# --------------------------------------------------------------------------- #

section "MPI unit validator  (bin/traffic_validator_mpi)"

for np in 1 2 4; do
    if [[ "$np" -gt "$NP_VALIDATOR" ]]; then
        info "np=${np} skipped  (${AVAIL_CORES} core(s) available, max np=${NP_VALIDATOR})"
        continue
    fi

    VALIDATOR_OUT=$(mpi_run "$np" "${BIN_DIR}/traffic_validator_mpi" 2>&1)
    EXIT_CODE=$?

    if [[ "$EXIT_CODE" -eq 0 ]]; then
        pass "validator np=${np}  (all unit tests passed)"
    else
        fail "validator np=${np}  (exit code ${EXIT_CODE})"
        echo "$VALIDATOR_OUT" | grep '\[FAIL\]' | sed 's/^/         /'
    fi
done

# --------------------------------------------------------------------------- #
# 4. Boundary conditions  (density=0.0 and density=1.0 → velocity=0.0)       #
# --------------------------------------------------------------------------- #

section "Boundary conditions  (density=0.0 and density=1.0)"

for np in 1 2 4; do
    if [[ "$np" -gt "$NP_MAX" ]]; then
        info "np=${np} skipped"
        continue
    fi

    OUT=$(mpi_run "$np" "${BIN_DIR}/traffic_mpi_opt" \
          "$N" 0.0 "$MAX_WARMUP" "$MEASURE_STEPS" 2>/dev/null)
    VEL=$(parse_velocity "$OUT")
    check_float_near_zero "$VEL" "np=${np}  density=0.0  velocity=0"

    OUT=$(mpi_run "$np" "${BIN_DIR}/traffic_mpi_opt" \
          "$N" 1.0 "$MAX_WARMUP" "$MEASURE_STEPS" 2>/dev/null)
    VEL=$(parse_velocity "$OUT")
    check_float_near_zero "$VEL" "np=${np}  density=1.0  velocity=0"
done

# --------------------------------------------------------------------------- #
# 5. Velocity range sanity                                                    #
# --------------------------------------------------------------------------- #

section "Velocity range sanity  (low / high density)"

for np in 1 2 4; do
    if [[ "$np" -gt "$NP_MAX" ]]; then
        info "np=${np} skipped"
        continue
    fi

    OUT=$(mpi_run "$np" "${BIN_DIR}/traffic_mpi_opt" \
          "$N" "$LOW_DENSITY" "$MAX_WARMUP" "$MEASURE_STEPS" 2>/dev/null)
    VEL=$(parse_velocity "$OUT")
    check_float_in_range "$VEL" "$LOW_VEL_MIN" "$LOW_VEL_MAX" \
        "np=${np}  density=${LOW_DENSITY}  velocity in [${LOW_VEL_MIN}, ${LOW_VEL_MAX}]"

    OUT=$(mpi_run "$np" "${BIN_DIR}/traffic_mpi_opt" \
          "$N" "$HIGH_DENSITY" "$MAX_WARMUP" "$MEASURE_STEPS" 2>/dev/null)
    VEL=$(parse_velocity "$OUT")
    check_float_in_range "$VEL" "$HIGH_VEL_MIN" "$HIGH_VEL_MAX" \
        "np=${np}  density=${HIGH_DENSITY}  velocity in [${HIGH_VEL_MIN}, ${HIGH_VEL_MAX}]"
done

# --------------------------------------------------------------------------- #
# 6. Multi-process output consistency  (density=0.5)                         #
# --------------------------------------------------------------------------- #

section "Multi-process output consistency  (density=0.5)"

for np in 1 2 4; do
    if [[ "$np" -gt "$NP_MAX" ]]; then
        info "np=${np} skipped"
        continue
    fi

    OUT=$(mpi_run "$np" "${BIN_DIR}/traffic_mpi_opt" \
          "$N" 0.5 "$MAX_WARMUP" "$MEASURE_STEPS" 2>/dev/null)
    EXIT_CODE=$?

    if [[ "$EXIT_CODE" -ne 0 ]]; then
        fail "np=${np}  density=0.5  exited with code ${EXIT_CODE}"
        continue
    fi

    check_output_format "$OUT" "np=${np}  density=0.5  output format"

    VEL=$(parse_velocity "$OUT")
    check_float_in_range "$VEL" "0.0" "1.0" \
        "np=${np}  density=0.5  velocity in [0, 1]"
done

# --------------------------------------------------------------------------- #
# 7. Output format contract  (mpi_opt vs seq_mem_opt)                        #
# --------------------------------------------------------------------------- #

section "Output format contract  (mpi_opt vs seq_mem_opt)"

SEQ_OUT=$("${BIN_DIR}/traffic_seq_mem_opt" \
          "$N" 0.5 "$MAX_WARMUP" "$MEASURE_STEPS" 2>/dev/null)
MPI_OUT=$(mpi_run 1 "${BIN_DIR}/traffic_mpi_opt" \
          "$N" 0.5 "$MAX_WARMUP" "$MEASURE_STEPS" 2>/dev/null)

SEQ_FIELDS=$(echo "$SEQ_OUT" | awk '{print NF}')
MPI_FIELDS=$(echo "$MPI_OUT" | awk '{print NF}')

if [[ "$SEQ_FIELDS" == "2" && "$MPI_FIELDS" == "2" ]]; then
    pass "both seq_mem_opt and mpi_opt output exactly 2 fields"
else
    fail "field count mismatch  (seq=${SEQ_FIELDS:-0}, mpi=${MPI_FIELDS:-0})"
fi

MPI_TIME=$(parse_time "$MPI_OUT")
if awk "BEGIN { exit !($MPI_TIME > 0.0) }"; then
    pass "mpi_opt time field is positive  (${MPI_TIME} ms)"
else
    fail "mpi_opt time field is not positive  (${MPI_TIME:-empty})"
fi

MPI_VEL=$(parse_velocity "$MPI_OUT")
check_float_in_range "$MPI_VEL" "0.0" "1.0" \
    "mpi_opt np=1 velocity in [0, 1]"

# --------------------------------------------------------------------------- #
# Summary                                                                     #
# --------------------------------------------------------------------------- #

echo ""
echo -e "${BOLD}------------------------------------------------------------${NC}"
TOTAL=$((PASS_COUNT + FAIL_COUNT))
if [[ "$FAIL_COUNT" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All ${TOTAL} tests passed.${NC}"
    echo -e "${BOLD}------------------------------------------------------------${NC}"
    exit 0
else
    echo -e "${RED}${BOLD}${FAIL_COUNT} / ${TOTAL} tests FAILED.${NC}"
    echo -e "${BOLD}------------------------------------------------------------${NC}"
    exit 1
fi