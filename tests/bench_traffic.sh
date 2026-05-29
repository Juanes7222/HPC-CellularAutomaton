#!/usr/bin/env bash
# =============================================================================
# bench_traffic.sh  --  Traffic Automaton Benchmark
#
# Runs all measurement combinations and writes every result to a single CSV.
# No analysis is performed here; that is the responsibility of report.py.
#
# Measurement matrix
# ------------------
# Scaling experiment  (all N x all thread counts, density=0.50):
#   Answers: how does parallelism scale? where does memory bandwidth limit speedup?
#
# Compiler-opt experiment  (same N x same thread counts, density=0.50):
#   Answers: what is the speedup from compiler optimisation alone?
#   Uses traffic_seq_opt (serial) and traffic_omp_opt (OpenMP) binaries,
#   built from identical source with OPT_FLAGS (-O3 -march=native -flto ...).
#
# Density experiment  (N=20M, threads=seq+4+8+12, all density values):
#   Answers: does car density (branch predictability) affect throughput?
#   N=20M is intentionally outside N_VALUES (dedicated 160 MB working point).
#   Deduplication (row_already_recorded) only prevents re-running rows on
#   --resume; it does NOT link rows between experiments.
#
# Loop order: repetition (outer) -> configuration (inner)
# -------------------------------------------------------
# Critical for benchmark validity: large-N runs flush the cache between
# consecutive measurements of small-N configurations, ensuring cold-cache
# conditions for every configuration in every repetition round.
#
# impl values written to CSV
# ---------------------------
#   traffic_seq      serial,  -O0  (baseline)
#   traffic_seq_opt  serial,  -O3 + march=native + flto + ...
#   traffic_omp      OpenMP,  -O0
#   traffic_omp_opt  OpenMP,  -O3 + march=native + flto + ...
#
# Fixes applied (v3)
# -------------------
#   [FIX-1]  DENSITY_EXPERIMENT_N comment corrected (N=20M never in N_VALUES).
#   [FIX-3]  sudo_keeper_pid: 'local' separated from $! assignment.
#   [FIX-4]  EXIT trap moved before optimize_system.
#   [FIX-5]  mkdir -p guard in print_raw_averages.
#   [FIX-6]  run_binary regex: (\.[0-9]*)? accepts bare integers.
#   [FIX-7]  DENSITY_EXPERIMENT_THREADS expanded to (0 4 8 12).
#   [NEW]    Four-binary support: seq, seq_opt, omp, omp_opt.
#
# Runs selected measurement combinations and writes every result to a single CSV.
# No analysis is performed here; that is the responsibility of report.py.
#
# Usage examples:
#   ./tests/benchmarks/bench_traffic.sh --machine machine1 --secuencial --secuencial-opt
#   ./tests/benchmarks/bench_traffic.sh --machine machine2 --omp --omp-opt
#   ./tests/benchmarks/bench_traffic.sh machine1 --all
#
# Output:
#   tests/<machine_flag>/results_traffic/data.csv
#
# =============================================================================

set -euo pipefail
export LC_NUMERIC=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# shellcheck source=tests/bench_utils.sh
source "tests/bench_utils.sh"

MACHINE_FLAG="machine1"

RUN_ALL=true
RUN_SEQ=false
RUN_SEQ_OPT=false
RUN_OMP=false
RUN_OMP_OPT=false
RUN_SEQ_MEM=false
RUN_SEQ_MEM_OPT=false
RUN_OMP_MEM=false
RUN_OMP_MEM_OPT=false

usage() {
    cat <<'EOF'
Usage:
  ./tests/benchmarks/bench_traffic.sh [options]

Options:
  --machine NAME            Machine name used in tests/NAME/results_traffic
  --secuencial              Run traffic_seq
  --secuencial-opt          Run traffic_seq_opt
  --omp                     Run traffic_omp
  --omp-opt                 Run traffic_omp_opt
  --secuencial-mem          Run traffic_seq_mem
  --secuencial-mem-opt      Run traffic_seq_mem_opt
  --omp-mem                 Run traffic_omp_mem
  --omp-mem-opt             Run traffic_omp_mem_opt
  --all                     Run every implementation
  -h, --help                Show this help

Compatibility:
  You may also pass the machine name as the first positional argument.
EOF
}

enable_selected_mode() {
    RUN_ALL=false
}

parse_args() {
    # Backward compatibility: if first arg does not start with '-', treat it as machine.
    if [[ $# -gt 0 && "${1}" != -* ]]; then
        MACHINE_FLAG="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --machine)
                MACHINE_FLAG="${2:?Missing value for --machine}"
                shift 2
                ;;

            --machine=*)
                MACHINE_FLAG="${1#*=}"
                shift
                ;;

            --secuencial|--seq)
                enable_selected_mode
                RUN_SEQ=true
                shift
                ;;

            --secuencial-opt|--seq-opt)
                enable_selected_mode
                RUN_SEQ_OPT=true
                shift
                ;;

            --omp)
                enable_selected_mode
                RUN_OMP=true
                shift
                ;;

            --omp-opt)
                enable_selected_mode
                RUN_OMP_OPT=true
                shift
                ;;

            --secuencial-mem|--seq-mem)
                enable_selected_mode
                RUN_SEQ_MEM=true
                shift
                ;;

            --secuencial-mem-opt|--seq-mem-opt)
                enable_selected_mode
                RUN_SEQ_MEM_OPT=true
                shift
                ;;

            --omp-mem|--omp-mem)
                enable_selected_mode
                RUN_OMP_MEM=true
                shift
                ;;

            --omp-mem-opt|--omp-mem-opt)
                enable_selected_mode
                RUN_OMP_MEM_OPT=true
                shift
                ;;

            --all)
                RUN_ALL=true
                RUN_SEQ=true
                RUN_SEQ_OPT=true
                RUN_OMP=true
                RUN_OMP_OPT=true
                RUN_SEQ_MEM=true
                RUN_SEQ_MEM_OPT=true
                RUN_OMP_MEM=true
                RUN_OMP_MEM_OPT=true
                shift
                ;;

            -h|--help)
                usage
                exit 0
                ;;

            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Default behavior: if nothing explicit was selected, run everything.
    if [[ "${RUN_ALL}" == true ]]; then
        RUN_SEQ=true
        RUN_SEQ_OPT=true
        RUN_OMP=true
        RUN_OMP_OPT=true
        RUN_SEQ_MEM=true
        RUN_SEQ_MEM_OPT=true
        RUN_OMP_MEM=true
        RUN_OMP_MEM_OPT=true
    fi
}

want_impl() {
    case "$1" in
        traffic_seq)        [[ "${RUN_SEQ}" == true ]] ;;
        traffic_seq_opt)    [[ "${RUN_SEQ_OPT}" == true ]] ;;
        traffic_omp)        [[ "${RUN_OMP}" == true ]] ;;
        traffic_omp_opt)    [[ "${RUN_OMP_OPT}" == true ]] ;;
        traffic_seq_mem)    [[ "${RUN_SEQ_MEM}" == true ]] ;;
        traffic_seq_mem_opt) [[ "${RUN_SEQ_MEM_OPT}" == true ]] ;;
        traffic_omp_mem)    [[ "${RUN_OMP_MEM}" == true ]] ;;
        traffic_omp_mem_opt) [[ "${RUN_OMP_MEM_OPT}" == true ]] ;;
        *) return 1 ;;
    esac
}

selected_impls_string() {
    local impls=()

    want_impl traffic_seq         && impls+=("seq")
    want_impl traffic_seq_opt     && impls+=("seq_opt")
    want_impl traffic_omp         && impls+=("omp")
    want_impl traffic_omp_opt     && impls+=("omp_opt")
    want_impl traffic_seq_mem     && impls+=("seq_mem")
    want_impl traffic_seq_mem_opt && impls+=("seq_mem_opt")
    want_impl traffic_omp_mem     && impls+=("omp_mem")
    want_impl traffic_omp_mem_opt && impls+=("omp_mem_opt")

    echo "${impls[*]:-none}"
}


BIN_DIR="bin"
RESULTS_DIR="tests/${MACHINE_FLAG}/results_traffic"
CSV="${RESULTS_DIR}/data.csv"

BIN_SEQ="${BIN_DIR}/traffic_seq"
BIN_SEQ_OPT="${BIN_DIR}/traffic_seq_opt"
BIN_OMP="${BIN_DIR}/traffic_omp"
BIN_OMP_OPT="${BIN_DIR}/traffic_omp_opt"
BIN_TESTS="${BIN_DIR}/traffic_tests"
BIN_SEQ_MEM="${BIN_DIR}/traffic_seq_mem"
BIN_SEQ_MEM_OPT="${BIN_DIR}/traffic_seq_mem_opt"
BIN_OMP_MEM="${BIN_DIR}/traffic_omp_mem"
BIN_OMP_MEM_OPT="${BIN_DIR}/traffic_omp_mem_opt"

ALL_THREAD_COUNTS=(0 2 4 6 8 12)

MEASURE_STEPS=1000

# N values for the scaling experiment — one per memory level.
# Working set = 2 × N × 4 bytes (two int32 buffers):
#   N =     8 000  →    64 KB  (L1-bound)
#   N =    64 000  →   512 KB  (L2-bound)
#   N =   500 000  →     4 MB  (upper L3)
#   N = 2 000 000  →    16 MB  (L3/DRAM boundary)
#   N = 5 000 000  →    40 MB  (RAM-bound, strong-scaling reference)
#   N =10 000 000  →    80 MB  (clearly DRAM-bound)
N_VALUES=(8000 64000 500000 2000000 5000000 10000000)

# Density fixed for the scaling and compiler-opt experiments.
SCALING_DENSITY="0.50"

# Density experiment parameters.
# N=20M (160 MB) is intentionally NOT in N_VALUES — dedicated DRAM-bound point.
DENSITY_EXPERIMENT_N=20000000
DENSITY_EXPERIMENT_THREADS=(0 4 8 12)
DENSITY_VALUES=(0.10 0.30 0.50 0.70 0.90)

REPETITIONS=10

# CPU pinning.
BENCH_CPUS="0,1,2,3,4,5,6,7,8,9,10,11"
BENCH_CPU_SINGLE="0"

CSV_HEADER="impl,threads,road_length,density,repetition,wall_time_ms,avg_velocity"


binaries_are_built() {
    [[ -x "${BIN_SEQ}"         && -x "${BIN_SEQ_OPT}"     &&
       -x "${BIN_OMP}"         && -x "${BIN_OMP_OPT}"     &&
       -x "${BIN_SEQ_MEM}"     && -x "${BIN_SEQ_MEM_OPT}" &&
       -x "${BIN_OMP_MEM}"     && -x "${BIN_OMP_MEM_OPT}" &&
       -x "${BIN_TESTS}" ]]
}

compile_all_binaries() {
    log_section "Compiling binaries"
    mkdir -p "${BIN_DIR}"
    if make all >/dev/null 2>&1; then
        log_ok "All binaries compiled (seq, seq_opt, omp, omp_opt, tests)."
    else
        log_error "Compilation failed. Run 'make all' to see errors."
        exit 1
    fi
}

warmup_ceiling_for() {
    local road_length="$1"
    local ceiling=$(( road_length / 10 ))
    [[ "${ceiling}" -lt 2000 ]] && ceiling=2000
    echo "${ceiling}"
}

row_already_recorded() {
    local impl="$1" threads="$2" road_length="$3" density="$4" rep="$5"
    awk -F',' \
        -v im="${impl}" -v th="${threads}" \
        -v rl="${road_length}" -v de="${density}" -v re="${rep}" \
        'NR>1 && $1==im && $2==th && $3==rl && $4==de && $5==re { found=1 }
         END { print found+0 }' \
        "${CSV}" 2>/dev/null
}

run_binary() {
    local impl="$1" road_length="$2" density="$3" threads="$4"
    local max_warmup exit_code=0 output
    max_warmup=$(warmup_ceiling_for "${road_length}")

    case "${impl}" in
        traffic_seq)
            output=$(taskset -c "${BENCH_CPU_SINGLE}" \
                "${BIN_SEQ}" "${road_length}" "${density}" \
                "${max_warmup}" "${MEASURE_STEPS}" 2>/dev/null) \
                || exit_code=$?
            ;;
        traffic_seq_opt)
            output=$(taskset -c "${BENCH_CPU_SINGLE}" \
                "${BIN_SEQ_OPT}" "${road_length}" "${density}" \
                "${max_warmup}" "${MEASURE_STEPS}" 2>/dev/null) \
                || exit_code=$?
            ;;
        traffic_seq_mem)
            output=$(taskset -c "${BENCH_CPU_SINGLE}" \
                "${BIN_SEQ_MEM}" "${road_length}" "${density}" \
                "${max_warmup}" "${MEASURE_STEPS}" 2>/dev/null) \
                || exit_code=$?
            ;;
        traffic_seq_mem_opt)
            output=$(taskset -c "${BENCH_CPU_SINGLE}" \
                "${BIN_SEQ_MEM_OPT}" "${road_length}" "${density}" \
                "${max_warmup}" "${MEASURE_STEPS}" 2>/dev/null) \
                || exit_code=$?
            ;;
        traffic_omp)
            output=$(sudo chrt -f 99 taskset -c "${BENCH_CPUS}" \
                "${BIN_OMP}" "${road_length}" "${density}" \
                "${max_warmup}" "${MEASURE_STEPS}" "${threads}" 2>/dev/null) \
                || exit_code=$?
            ;;
        traffic_omp_opt)
            output=$(sudo chrt -f 99 taskset -c "${BENCH_CPUS}" \
                "${BIN_OMP_OPT}" "${road_length}" "${density}" \
                "${max_warmup}" "${MEASURE_STEPS}" "${threads}" 2>/dev/null) \
                || exit_code=$?
            ;;
        traffic_omp_mem)
            output=$(sudo chrt -f 99 taskset -c "${BENCH_CPUS}" \
                "${BIN_OMP_MEM}" "${road_length}" "${density}" \
                "${max_warmup}" "${MEASURE_STEPS}" "${threads}" 2>/dev/null) \
                || exit_code=$?
            ;;
        traffic_omp_mem_opt)
            output=$(sudo chrt -f 99 taskset -c "${BENCH_CPUS}" \
                "${BIN_OMP_MEM_OPT}" "${road_length}" "${density}" \
                "${max_warmup}" "${MEASURE_STEPS}" "${threads}" 2>/dev/null) \
                || exit_code=$?
            ;;
        *)
            log_error "Unknown impl: '${impl}'"
            echo "0.000 0.000000"
            return
            ;;
    esac

    if [[ "${exit_code}" -ne 0 || -z "${output}" ]]; then
        log_error "Binary failed (impl=${impl} N=${road_length} d=${density} t=${threads})"
        echo "0.000 0.000000"
        return
    fi

    local ms velocity
    ms=$(echo "${output}" | awk '{print $1}')
    velocity=$(echo "${output}" | awk '{print $2}')

    if ! [[ "${ms}" =~ ^[0-9]+(\.[0-9]*)?$ && "${velocity}" =~ ^[0-9]+(\.[0-9]*)?$ ]]; then
        log_error "Unexpected binary output: '${output}'"
        echo "0.000 0.000000"
        return
    fi

    echo "${ms} ${velocity}"
}

append_result_row() {
    local impl="$1" threads="$2" road_length="$3" \
          density="$4" rep="$5" ms="$6" velocity="$7"
    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "${impl}" "${threads}" "${road_length}" \
        "${density}" "${rep}" "${ms}" "${velocity}" >> "${CSV}"
    sync
}

add_cfg() {
    local -n arr="$1"
    local impl="$2" threads="$3" road_length="$4" density="$5"
    arr+=("${impl}|${threads}|${road_length}|${density}")
}

# Scaling experiment: selected implementations at all thread counts.
build_scaling_configurations() {
    local -n out_array="$1"
    out_array=()

    for threads in "${ALL_THREAD_COUNTS[@]}"; do
        for road_length in "${N_VALUES[@]}"; do
            if [[ "${threads}" -eq 0 ]]; then
                want_impl traffic_seq         && add_cfg out_array traffic_seq         "${threads}" "${road_length}" "${SCALING_DENSITY}"
                want_impl traffic_seq_opt     && add_cfg out_array traffic_seq_opt     "${threads}" "${road_length}" "${SCALING_DENSITY}"
                want_impl traffic_seq_mem     && add_cfg out_array traffic_seq_mem     "${threads}" "${road_length}" "${SCALING_DENSITY}"
                want_impl traffic_seq_mem_opt && add_cfg out_array traffic_seq_mem_opt "${threads}" "${road_length}" "${SCALING_DENSITY}"
            else
                want_impl traffic_omp         && add_cfg out_array traffic_omp         "${threads}" "${road_length}" "${SCALING_DENSITY}"
                want_impl traffic_omp_opt     && add_cfg out_array traffic_omp_opt     "${threads}" "${road_length}" "${SCALING_DENSITY}"
                want_impl traffic_omp_mem     && add_cfg out_array traffic_omp_mem     "${threads}" "${road_length}" "${SCALING_DENSITY}"
                want_impl traffic_omp_mem_opt && add_cfg out_array traffic_omp_mem_opt "${threads}" "${road_length}" "${SCALING_DENSITY}"
            fi
        done
    done
}

# Density experiment: selected implementations at the density sweep points.
build_density_configurations() {
    local -n out_array="$1"
    out_array=()

    for threads in "${DENSITY_EXPERIMENT_THREADS[@]}"; do
        for density in "${DENSITY_VALUES[@]}"; do
            if [[ "${threads}" -eq 0 ]]; then
                want_impl traffic_seq         && add_cfg out_array traffic_seq         "${threads}" "${DENSITY_EXPERIMENT_N}" "${density}"
                want_impl traffic_seq_opt     && add_cfg out_array traffic_seq_opt     "${threads}" "${DENSITY_EXPERIMENT_N}" "${density}"
                want_impl traffic_seq_mem     && add_cfg out_array traffic_seq_mem     "${threads}" "${DENSITY_EXPERIMENT_N}" "${density}"
                want_impl traffic_seq_mem_opt && add_cfg out_array traffic_seq_mem_opt "${threads}" "${DENSITY_EXPERIMENT_N}" "${density}"
            else
                want_impl traffic_omp         && add_cfg out_array traffic_omp         "${threads}" "${DENSITY_EXPERIMENT_N}" "${density}"
                want_impl traffic_omp_opt     && add_cfg out_array traffic_omp_opt     "${threads}" "${DENSITY_EXPERIMENT_N}" "${density}"
                want_impl traffic_omp_mem     && add_cfg out_array traffic_omp_mem     "${threads}" "${DENSITY_EXPERIMENT_N}" "${density}"
                want_impl traffic_omp_mem_opt && add_cfg out_array traffic_omp_mem_opt "${threads}" "${DENSITY_EXPERIMENT_N}" "${density}"
            fi
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
            impl=$(echo "${config}" | cut -d'|' -f1)
            threads=$(echo "${config}" | cut -d'|' -f2)
            road_length=$(echo "${config}" | cut -d'|' -f3)
            density=$(echo "${config}" | cut -d'|' -f4)

            if [[ "$(row_already_recorded "${impl}" "${threads}" \
                    "${road_length}" "${density}" "${rep}")" -gt 0 ]]; then
                log_info "  [SKIP] ${impl} t=${threads} N=${road_length} d=${density} rep=${rep}"
                continue
            fi

            printf "  rep=%-2s  impl=%-16s  N=%-10s  d=%-4s  t=%-3s  " \
                "${rep}" "${impl}" "${road_length}" "${density}" "${threads}"

            local output ms velocity
            output=$(run_binary "${impl}" "${road_length}" "${density}" "${threads}")
            ms=$(echo "${output}" | awk '{print $1}')
            velocity=$(echo "${output}" | awk '{print $2}')

            printf "%s ms  v=%.4f\n" "${ms}" "${velocity}"

            append_result_row "${impl}" "${threads}" "${road_length}" \
                "${density}" "${rep}" "${ms}" "${velocity}"
        done
    done
}

print_raw_averages() {
    mkdir -p "${RESULTS_DIR}"
    local summary="${RESULTS_DIR}/summary_raw.txt"

    {
        awk -F',' '
        NR==1 { next }
        $6+0 > 0 {
            key = $1 SUBSEP $2 SUBSEP $3 SUBSEP $4
            sum_ms[key] += $6; sum_v[key] += $7; cnt[key]++
        }
        END {
            for (k in sum_ms) {
                split(k, a, SUBSEP)
                printf "%s|%s|%s|%s|%.1f|%.4f\n",
                    a[1], a[2], a[3], a[4],
                    sum_ms[k]/cnt[k], sum_v[k]/cnt[k]
            }
        }' "${CSV}" | sort -t'|' -k3,3n -k4,4g -k1,1 -k2,2n \
        | awk -F'|' 'BEGIN {
            printf "%-20s  %-7s  %-12s  %-7s  %9s  %9s\n",
                "impl","threads","road_length","density","avg_ms","avg_vel"
            printf "%-20s  %-7s  %-12s  %-7s  %9s  %9s\n",
                "--------------------","-------","------------","-------",
                "---------","---------"
        }
        { printf "%-20s  %-7s  %-12s  %-7s  %9.1f  %9.4f\n",
            $1,$2,$3,$4,$5,$6 }'
    } | tee "${summary}"

    echo ""
    log_ok "Raw averages : ${summary}"
    log_ok "Full dataset : ${CSV}"
}

print_banner() {
    echo -e "${BOLD}"
    echo "================================================================"
    echo "   Traffic Automaton — OpenMP + Compiler-Opt Benchmark"
    echo "   Machine          : ${MACHINE_FLAG}"
    echo "   Host             : $(cat /etc/hostname 2>/dev/null \
                                    || cat /proc/sys/kernel/hostname 2>/dev/null \
                                    || echo 'unknown')"
    echo "   Selected impls   : $(selected_impls_string)"
    echo "   N values         : ${N_VALUES[*]}"
    echo "   Thread counts    : ${ALL_THREAD_COUNTS[*]}"
    echo "   Measure steps    : ${MEASURE_STEPS}"
    echo "   Repetitions      : ${REPETITIONS}"
    echo "   Bench CPUs       : ${BENCH_CPUS}"
    echo "   Density exp N    : ${DENSITY_EXPERIMENT_N}"
    echo "   Density threads  : ${DENSITY_EXPERIMENT_THREADS[*]}"
    echo "   Binaries         : seq  seq_opt  seq_mem  seq_mem_opt  omp  omp_opt  omp_mem  omp_mem_opt"
    echo "   Loop order       : repetition (outer) -> config (inner)"
    echo "   Date             : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================================"
    echo -e "${RESET}"
}

inhibit_sleep() {
    [[ -n "${BENCH_INHIBIT_ACTIVE:-}" ]] && return 0

    if ! command -v systemd-inhibit &>/dev/null; then
        log_warn "systemd-inhibit not found — machine may suspend during benchmark."
        return 1
    fi

    log_info "Acquiring sleep/suspend inhibitor via systemd-inhibit..."

    export BENCH_INHIBIT_ACTIVE=1

    if ! systemd-inhibit \
        --what=sleep:idle \
        --who="bench_traffic" \
        --why="Benchmark in progress — do not suspend" \
        --mode=block \
        bash "${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")" "$@"; then

        log_warn "Failed to acquire systemd inhibitor lock."
        log_warn "Continuing benchmark without suspend protection."
        return 0
    fi

    exit 0
}

main() {
    parse_args "$@"

    if [[ -z "${BENCH_INHIBIT_ACTIVE:-}" ]]; then
        inhibit_sleep "$@"
    fi

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

    local sudo_keeper_pid
    ( while true; do sudo -nv 2>/dev/null; sleep 55; done ) &
    sudo_keeper_pid=$!

    trap 'kill "${sudo_keeper_pid}" 2>/dev/null; restore_system' EXIT

    optimize_system
    print_banner
    run_benchmark

    echo ""
    print_raw_averages
}

main "$@"