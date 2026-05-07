#!/usr/bin/env bash
# =============================================================================
# bench_traffic.sh  --  Traffic Automaton OpenMP Benchmark
#
# Runs all measurement combinations and writes every result to a single CSV.
# No analysis is performed here — that is the responsibility of a separate
# script that reads the CSV after the benchmark completes.
#
# Measurement matrix
# ------------------
# Scaling experiment  (all N × all thread counts, density=0.50):
#   Answers: how does parallelism scale? where does memory bandwidth limit speedup?
#
# Density experiment  (N=2M, threads=seq+12, all density values):
#   Answers: does car density (branch predictability) affect throughput?
#   Rows already covered by the scaling experiment are skipped automatically.
#
# Loop order: repetition (outer) → configuration (inner)
# -------------------------------------------------------
# This is critical for benchmark validity. If repetitions were the inner loop,
# consecutive measurements of the same configuration would find the working set
# already hot in cache. By running all configurations once per repetition round,
# large-N runs (N=10M, 80 MB working set) flush the cache between consecutive
# measurements of small-N configurations, ensuring cold-cache conditions.
#
# Convergence validation via avg_velocity
# ----------------------------------------
# Each binary outputs "wall_time_ms avg_velocity" on stdout. The avg_velocity
# is the mean car velocity over the measure phase. For a given (N, density),
# converged runs across repetitions should produce nearly identical velocity
# values. Large variance across reps is a direct indicator that the warmup
# ceiling was too low and steady state was not reached before timing started.
#
# Usage:
#   ./tests/benchmarks/bench_traffic.sh [machine_flag]
#   machine_flag defaults to "machine1"
#
# Output:
#   tests/<machine_flag>/results_traffic/data.csv
#
# Requires: bench_utils.sh in the same directory.
# =============================================================================

set -euo pipefail
export LC_NUMERIC=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# shellcheck source=tests/bench_utils.sh
source "tests/bench_utils.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

MACHINE_FLAG="${1:-machine1}"

BIN_DIR="bin"
RESULTS_DIR="tests/${MACHINE_FLAG}/results_traffic"
CSV="${RESULTS_DIR}/data.csv"

BIN_SEQ="${BIN_DIR}/traffic_seq"
BIN_OMP="${BIN_DIR}/traffic_omp"
BIN_TESTS="${BIN_DIR}/traffic_tests"

# Thread counts to benchmark. 0 means sequential (traffic_seq binary).
ALL_THREAD_COUNTS=(0 2 4 6 8 12)

# Number of timed steps per measurement (warmup excluded from the clock).
MEASURE_STEPS=1000

# N values — one per memory level.
# Working set = 2 × N × 4 bytes (two int buffers):
#   N =     8 000  →    64 KB  (L1-bound)
#   N =    64 000  →   512 KB  (L2-bound)
#   N =   500 000  →     4 MB  (upper L3)
#   N = 2 000 000  →    16 MB  (L3/DRAM boundary)
#   N = 5 000 000  →    40 MB  (RAM-bound, strong-scaling reference)
#   N =10 000 000  →    80 MB  (clearly DRAM-bound)
N_VALUES=(8000 64000 500000 2000000 5000000 10000000)

# Density fixed for the scaling experiment.
SCALING_DENSITY="0.50"

# Density experiment parameters.
DENSITY_EXPERIMENT_N=20000000
DENSITY_EXPERIMENT_THREADS=(0 12)
DENSITY_VALUES=(0.10 0.30 0.50 0.70 0.90)

REPETITIONS=10

# CPU pinning.
BENCH_CPUS="0,1,2,3,4,5,6,7,8,9,10,11"
BENCH_CPU_SINGLE="0"

CSV_HEADER="impl,threads,road_length,density,repetition,wall_time_ms,avg_velocity"

# ---------------------------------------------------------------------------
# Compilation
# ---------------------------------------------------------------------------

binaries_are_built() {
    [[ -x "${BIN_SEQ}" && -x "${BIN_OMP}" && -x "${BIN_TESTS}" ]]
}

compile_all_binaries() {
    log_section "Compiling binaries"
    mkdir -p "${BIN_DIR}"
    if make all >/dev/null 2>&1; then
        log_ok "All binaries compiled."
    else
        log_error "Compilation failed. Run 'make all' to see errors."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Warmup ceiling
# ---------------------------------------------------------------------------

warmup_ceiling_for() {
    local road_length="$1"
    local ceiling=$(( road_length / 10 ))
    [[ "${ceiling}" -lt 2000 ]] && ceiling=2000
    echo "${ceiling}"
}

# ---------------------------------------------------------------------------
# Resume support
# ---------------------------------------------------------------------------

row_already_recorded() {
    local impl="$1" threads="$2" road_length="$3" density="$4" rep="$5"
    awk -F',' \
        -v im="${impl}" -v th="${threads}" \
        -v rl="${road_length}" -v de="${density}" -v re="${rep}" \
        'NR>1 && $1==im && $2==th && $3==rl && $4==de && $5==re { found=1 }
         END { print found+0 }' \
        "${CSV}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Single measurement
# ---------------------------------------------------------------------------

# Invokes the appropriate binary and echoes "wall_time_ms avg_velocity".
# The caller is responsible for splitting the two fields.
run_binary() {
    local road_length="$1" density="$2" threads="$3"
    local max_warmup exit_code=0 output
    max_warmup=$(warmup_ceiling_for "${road_length}")

    if [[ "${threads}" -eq 0 ]]; then
        output=$(taskset -c "${BENCH_CPU_SINGLE}" \
            "${BIN_SEQ}" "${road_length}" "${density}" \
            "${max_warmup}" "${MEASURE_STEPS}" 2>/dev/null) || exit_code=$?
    else
        output=$(sudo chrt -f 99 taskset -c "${BENCH_CPUS}" \
            "${BIN_OMP}" "${road_length}" "${density}" \
            "${max_warmup}" "${MEASURE_STEPS}" "${threads}" 2>/dev/null) \
            || exit_code=$?
    fi

    if [[ "${exit_code}" -ne 0 || -z "${output}" ]]; then
        log_error "Binary failed (N=${road_length} d=${density} t=${threads})"
        echo "0.000 0.000000"; return
    fi

    # Expected format from binary stdout: "229.582 0.412754"
    local ms velocity
    ms=$(      echo "${output}" | awk '{print $1}')
    velocity=$(echo "${output}" | awk '{print $2}')

    if ! [[ "${ms}" =~ ^[0-9]+(\.[0-9]+)?$ && \
            "${velocity}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_error "Unexpected binary output: '${output}'"
        echo "0.000 0.000000"; return
    fi

    echo "${ms} ${velocity}"
}

# ---------------------------------------------------------------------------
# CSV writing
# ---------------------------------------------------------------------------

append_result_row() {
    local impl="$1" threads="$2" road_length="$3" \
          density="$4" rep="$5" ms="$6" velocity="$7"
    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "${impl}" "${threads}" "${road_length}" \
        "${density}" "${rep}" "${ms}" "${velocity}" >> "${CSV}"
    sync
}

# ---------------------------------------------------------------------------
# Configuration list builders
# ---------------------------------------------------------------------------

build_scaling_configurations() {
    local -n out_array="$1"
    out_array=()
    for threads in "${ALL_THREAD_COUNTS[@]}"; do
        for road_length in "${N_VALUES[@]}"; do
            local impl="traffic_seq"
            [[ "${threads}" -gt 0 ]] && impl="traffic_omp"
            out_array+=("${impl}|${threads}|${road_length}|${SCALING_DENSITY}")
        done
    done
}

build_density_configurations() {
    local -n out_array="$1"
    out_array=()
    for threads in "${DENSITY_EXPERIMENT_THREADS[@]}"; do
        for density in "${DENSITY_VALUES[@]}"; do
            local impl="traffic_seq"
            [[ "${threads}" -gt 0 ]] && impl="traffic_omp"
            out_array+=("${impl}|${threads}|${DENSITY_EXPERIMENT_N}|${density}")
        done
    done
}

# ---------------------------------------------------------------------------
# Benchmark loop  (repetition outer, configuration inner)
# ---------------------------------------------------------------------------

run_benchmark() {
    local -a scaling_configs density_configs all_configs
    build_scaling_configurations scaling_configs
    build_density_configurations density_configs
    all_configs=("${scaling_configs[@]}" "${density_configs[@]}")

    log_section "Starting benchmark: ${#all_configs[@]} configurations × ${REPETITIONS} repetitions"

    for rep in $(seq 1 "${REPETITIONS}"); do
        log_section "Repetition ${rep} / ${REPETITIONS}"

        for config in "${all_configs[@]}"; do
            local impl threads road_length density
            impl=$(       echo "${config}" | cut -d'|' -f1)
            threads=$(    echo "${config}" | cut -d'|' -f2)
            road_length=$(echo "${config}" | cut -d'|' -f3)
            density=$(    echo "${config}" | cut -d'|' -f4)

            if [[ "$(row_already_recorded "${impl}" "${threads}" \
                    "${road_length}" "${density}" "${rep}")" -gt 0 ]]; then
                log_info "  [SKIP] ${impl}_${threads}t  N=${road_length}  d=${density}  rep=${rep}"
                continue
            fi

            printf "  rep=%-2s  N=%-10s  d=%-4s  threads=%-3s  " \
                "${rep}" "${road_length}" "${density}" "${threads}"

            local output ms velocity
            output=$(run_binary "${road_length}" "${density}" "${threads}")
            ms=$(      echo "${output}" | awk '{print $1}')
            velocity=$(echo "${output}" | awk '{print $2}')

            printf "%s ms  v=%.4f\n" "${ms}" "${velocity}"

            append_result_row "${impl}" "${threads}" "${road_length}" \
                "${density}" "${rep}" "${ms}" "${velocity}"
        done
    done
}

# ---------------------------------------------------------------------------
# End-of-run summary
# ---------------------------------------------------------------------------

print_raw_averages() {
    local summary="${RESULTS_DIR}/summary_raw.txt"

    {
        awk -F',' '
        NR==1 { next }
        $6+0 > 0 {
            key = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4
            sum_ms[key]  += $6; sum_v[key] += $7; cnt[key]++
        }
        END {
            for (k in sum_ms) {
                split(k, a, SUBSEP)
                printf "%s|%s|%s|%s|%.1f|%.4f\n",
                    a[1], a[2], a[3], a[4],
                    sum_ms[k]/cnt[k], sum_v[k]/cnt[k]
            }
        }' "${CSV}" | sort -t'|' -k3,3n -k4,4g -k2,2n \
        | awk -F'|' 'BEGIN {
            printf "%-16s  %-7s  %-12s  %-7s  %9s  %9s\n",
                "impl","threads","road_length","density","avg_ms","avg_vel"
            printf "%-16s  %-7s  %-12s  %-7s  %9s  %9s\n",
                "----------------","-------","------------","-------",
                "---------","---------"
        }
        { printf "%-16s  %-7s  %-12s  %-7s  %9.1f  %9.4f\n",
            $1,$2,$3,$4,$5,$6 }'
    } | tee "${summary}"

    echo ""
    log_ok "Raw averages : ${summary}"
    log_ok "Full dataset : ${CSV}"
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

print_banner() {
    echo -e "${BOLD}"
    echo "================================================================"
    echo "   Traffic Automaton — OpenMP Benchmark"
    echo "   Machine       : ${MACHINE_FLAG}"
    echo "   Host          :  $(cat /etc/hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null || echo 'unknown')"
    echo "   N values      : ${N_VALUES[*]}"
    echo "   Thread counts : ${ALL_THREAD_COUNTS[*]}"
    echo "   Measure steps : ${MEASURE_STEPS}"
    echo "   Repetitions   : ${REPETITIONS}"
    echo "   Bench CPUs    : ${BENCH_CPUS}"
    echo "   Loop order    : repetition (outer) -> config (inner)"
    echo "   Date          : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================================"
    echo -e "${RESET}"
}

# ---------------------------------------------------------------------------
# Sleep / suspend inhibitor
# ---------------------------------------------------------------------------

inhibit_sleep() {
    [[ -n "${BENCH_INHIBIT_ACTIVE:-}" ]] && return 0

    if ! command -v systemd-inhibit &>/dev/null; then
        log_warn "systemd-inhibit not found — machine may suspend during benchmark."
        log_warn "Consider running: sudo systemctl mask sleep.target suspend.target"
        return 0
    fi

    log_info "Acquiring sleep/suspend inhibitor via systemd-inhibit..."
    exec env BENCH_INHIBIT_ACTIVE=1 \
        systemd-inhibit \
            --what=sleep:suspend:hibernate:idle \
            --who="bench_traffic" \
            --why="Benchmark in progress — do not suspend" \
            --mode=block \
            bash "${BASH_SOURCE[0]}" "$@"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

main() {
    inhibit_sleep "$@"
    
    mkdir -p "${RESULTS_DIR}" "${BIN_DIR}"

    if ! binaries_are_built; then
        compile_all_binaries
    fi

    log_info "Running validation tests..."
    if ! "${BIN_TESTS}" >/dev/null 2>&1; then
        log_error "Validation tests FAILED. Fix the implementation before benchmarking."
        exit 1
    fi
    log_ok "All validation tests passed."

    setup_csv "${RESULTS_DIR}" "${CSV}" "${CSV_HEADER}"

    sudo -v
    ( while true; do sudo -nv 2>/dev/null; sleep 55; done ) &
    local sudo_keeper_pid=$!
    trap 'kill "${sudo_keeper_pid}" 2>/dev/null; restore_system' EXIT

    optimize_system
    print_banner
    run_benchmark

    echo ""
    print_raw_averages
}

main