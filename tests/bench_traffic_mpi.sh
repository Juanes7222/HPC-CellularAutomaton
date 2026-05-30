#!/usr/bin/env bash
# =============================================================================
# bench_traffic_mpi.sh  --  Traffic Automaton MPI Benchmark
#
# Runs all measurement combinations and writes every result to a single CSV.
# No analysis is performed here; that is the responsibility of report.py.
#
# Measurement matrix
# ------------------
# Scaling experiment  (all N x all np values, density=0.50)
# Compiler-opt experiment  (same N x same np, density=0.50)
# Density experiment  (N=DENSITY_EXPERIMENT_N, np=seq+1+4+8, all densities)
# =============================================================================

set -euo pipefail
export LC_NUMERIC=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# shellcheck source=tests/bench_utils.sh
source "tests/bench_utils.sh"

# ---------------------------------------------------------------------------
# State & Flags
# ---------------------------------------------------------------------------

MACHINE_FLAG="machine1"
MPIRUN="${MPIRUN:-mpirun}"

RUN_ALL=true
RUN_SEQ_MEM_OPT=false
RUN_MPI=false
RUN_MPI_OPT=false
INHIBIT_SLEEP=true
INTERNAL_RUN=false

usage() {
    cat <<'EOF'
Usage:
  ./tests/benchmarks/bench_traffic_mpi.sh [options]

Options:
  --machine NAME            Machine name used in tests/NAME/results_traffic_mpi
  --no-inhibit              Do not attempt to inhibit sleep/suspend (not recommended)
  --seq-mem-opt             Run traffic_seq_mem_opt (np=0 baseline)
  --mpi                     Run traffic_mpi (unoptimised)
  --mpi-opt                 Run traffic_mpi_opt (optimised)
  --all                     Run every implementation
  -h, --help                Show this help
EOF
}

enable_selected_mode() {
    RUN_ALL=false
}

parse_args() {
    if [[ $# -gt 0 && "${1}" != -* ]]; then
        MACHINE_FLAG="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --machine) MACHINE_FLAG="${2:?Missing value for --machine}"; shift 2 ;;
            --machine=*) MACHINE_FLAG="${1#*=}"; shift ;;
            --no-inhibit) INHIBIT_SLEEP=false; shift ;;
            --internal-run) INTERNAL_RUN=true; shift ;;
            --seq-mem-opt) enable_selected_mode; RUN_SEQ_MEM_OPT=true; shift ;;
            --mpi) enable_selected_mode; RUN_MPI=true; shift ;;
            --mpi-opt) enable_selected_mode; RUN_MPI_OPT=true; shift ;;
            --all) RUN_ALL=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) log_error "Unknown argument: $1"; usage; exit 1 ;;
        esac
    done

    if [[ "${RUN_ALL}" == true ]]; then
        RUN_SEQ_MEM_OPT=true
        RUN_MPI=true
        RUN_MPI_OPT=true
    fi
}

want_impl() {
    case "$1" in
        traffic_seq_mem_opt) [[ "${RUN_SEQ_MEM_OPT}" == true ]] && return 0 || return 1 ;;
        traffic_mpi) [[ "${RUN_MPI}" == true ]] && return 0 || return 1 ;;
        traffic_mpi_opt) [[ "${RUN_MPI_OPT}" == true ]] && return 0 || return 1 ;;
        *) return 1 ;;
    esac
}

selected_impls_string() {
    local impls=()
    if want_impl traffic_seq_mem_opt; then impls+=("seq_mem_opt"); fi
    if want_impl traffic_mpi; then impls+=("mpi"); fi
    if want_impl traffic_mpi_opt; then impls+=("mpi_opt"); fi
    echo "${impls[*]:-none}"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

BIN_DIR="bin"
RESULTS_DIR="tests/${MACHINE_FLAG}/results_traffic_mpi"
CSV="${RESULTS_DIR}/data.csv"

BIN_SEQ_MEM_OPT="${BIN_DIR}/traffic_seq_mem_opt"
BIN_MPI="${BIN_DIR}/traffic_mpi"
BIN_MPI_OPT="${BIN_DIR}/traffic_mpi_opt"
BIN_TESTS="${BIN_DIR}/traffic_tests"
BIN_VALIDATOR="${BIN_DIR}/traffic_validator_mpi"

ALL_NP_COUNTS=(0 1 2 4 8 12)
MEASURE_STEPS=1000
N_VALUES=(32000 256000 2000000 8000000 20000000 40000000)
SCALING_DENSITY="0.50"

DENSITY_EXPERIMENT_N=80000000
DENSITY_EXPERIMENT_NP=(0 1 4 8)
DENSITY_VALUES=(0.10 0.30 0.50 0.70 0.90)

REPETITIONS=10

BENCH_CPUS="0,1,2,3,4,5,6,7,8,9,10,11"
BENCH_CPU_SINGLE="0"

CSV_HEADER="impl,np,road_length,density,repetition,wall_time_ms,avg_velocity"

if [[ "$(id -u)" -eq 0 ]]; then
    export OMPI_ALLOW_RUN_AS_ROOT=1
    export OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
fi

# ---------------------------------------------------------------------------
# Core Functions
# ---------------------------------------------------------------------------

binaries_are_built() {
    [[ -x "${BIN_SEQ_MEM_OPT}" && -x "${BIN_MPI}" && \
       -x "${BIN_MPI_OPT}" && -x "${BIN_TESTS}" && -x "${BIN_VALIDATOR}" ]]
}

compile_all_binaries() {
    log_section "Compiling binaries"
    mkdir -p "${BIN_DIR}"
    if make seq_mem_opt mpi mpi_opt tests validator >/dev/null 2>&1; then
        log_ok "Binaries compiled successfully."
    else
        log_error "Compilation failed. Run 'make seq_mem_opt mpi mpi_opt tests validator'."
        exit 1
    fi
}

warmup_ceiling_for() {
    local road_length="$1"
    local ceiling=$(( road_length / 10 ))
    [[ "${ceiling}" -lt 2000 ]] && ceiling=2000
    echo "${ceiling}"
}

cpu_list_for_np() {
    local np="$1"
    local max_core
    max_core=$(echo "${BENCH_CPUS}" | tr ',' '\n' | wc -l)
    local end=$(( np < max_core ? np - 1 : max_core - 1 ))
    seq -s',' 0 "${end}"
}

row_already_recorded() {
    local impl="$1" np="$2" road_length="$3" density="$4" rep="$5"
    awk -F',' \
        -v im="${impl}" -v np="${np}" \
        -v rl="${road_length}" -v de="${density}" -v re="${rep}" \
        'NR>1 && $1==im && $2==np && $3==rl && $4==de && $5==re { found=1 }
         END { print found+0 }' \
        "${CSV}" 2>/dev/null
}

run_binary() {
    local impl="$1" road_length="$2" density="$3" np="$4"
    local max_warmup exit_code=0 output cpu_list
    max_warmup=$(warmup_ceiling_for "${road_length}")

    case "${impl}" in
        traffic_seq_mem_opt)
            output=$(taskset -c "${BENCH_CPU_SINGLE}" \
                "${BIN_SEQ_MEM_OPT}" "${road_length}" "${density}" \
                "${max_warmup}" "${MEASURE_STEPS}" 2>/dev/null) || exit_code=$?
            ;;
        traffic_mpi)
            cpu_list=$(cpu_list_for_np "${np}")
            output=$(sudo chrt -f 99 taskset -c "${cpu_list}" \
                "${MPIRUN}" --oversubscribe -np "${np}" --bind-to core --map-by core \
                "${BIN_MPI}" "${road_length}" "${density}" \
                "${max_warmup}" "${MEASURE_STEPS}" 2>/dev/null) || exit_code=$?
            ;;
        traffic_mpi_opt)
            cpu_list=$(cpu_list_for_np "${np}")
            output=$(sudo chrt -f 99 taskset -c "${cpu_list}" \
                "${MPIRUN}" --oversubscribe -np "${np}" --bind-to core --map-by core \
                "${BIN_MPI_OPT}" "${road_length}" "${density}" \
                "${max_warmup}" "${MEASURE_STEPS}" 2>/dev/null) || exit_code=$?
            ;;
        *)
            log_error "Unknown impl: '${impl}'"
            echo "0.000 0.000000"; return
            ;;
    esac

    if [[ "${exit_code}" -ne 0 || -z "${output}" ]]; then
        log_error "Binary failed (impl=${impl} N=${road_length} d=${density} np=${np})"
        echo "0.000 0.000000"; return
    fi

    local ms velocity
    ms=$(echo "${output}" | awk '{print $1}')
    velocity=$(echo "${output}" | awk '{print $2}')

    if ! [[ "${ms}" =~ ^[0-9]+(\.[0-9]*)?$ && "${velocity}" =~ ^[0-9]+(\.[0-9]*)?$ ]]; then
        log_error "Unexpected binary output: '${output}'"
        echo "0.000 0.000000"; return
    fi

    echo "${ms} ${velocity}"
}

append_result_row() {
    local impl="$1" np="$2" road_length="$3" density="$4" rep="$5" ms="$6" velocity="$7"
    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "${impl}" "${np}" "${road_length}" "${density}" "${rep}" "${ms}" "${velocity}" >> "${CSV}"
    sync
}

add_cfg() {
    local -n arr="$1"
    arr+=("$2|$3|$4|$5")
}

build_scaling_configurations() {
    local -n out_array="$1"
    out_array=()
    for np in "${ALL_NP_COUNTS[@]}"; do
        for road_length in "${N_VALUES[@]}"; do
            if [[ "${np}" -eq 0 ]]; then
                if want_impl traffic_seq_mem_opt; then
                    add_cfg out_array "traffic_seq_mem_opt" "${np}" "${road_length}" "${SCALING_DENSITY}"
                fi
            else
                if want_impl traffic_mpi; then
                    add_cfg out_array "traffic_mpi" "${np}" "${road_length}" "${SCALING_DENSITY}"
                fi
                if want_impl traffic_mpi_opt; then
                    add_cfg out_array "traffic_mpi_opt" "${np}" "${road_length}" "${SCALING_DENSITY}"
                fi
            fi
        done
    done
}

build_density_configurations() {
    local -n out_array="$1"
    out_array=()
    for np in "${DENSITY_EXPERIMENT_NP[@]}"; do
        for density in "${DENSITY_VALUES[@]}"; do
            if [[ "${np}" -eq 0 ]]; then
                if want_impl traffic_seq_mem_opt; then
                    add_cfg out_array "traffic_seq_mem_opt" "${np}" "${DENSITY_EXPERIMENT_N}" "${density}"
                fi
            else
                if want_impl traffic_mpi_opt; then
                    add_cfg out_array "traffic_mpi_opt" "${np}" "${DENSITY_EXPERIMENT_N}" "${density}"
                fi
            fi
        done
    done
}

run_benchmark() {
    local -a scaling_configs density_configs all_configs
    build_scaling_configurations scaling_configs
    build_density_configurations density_configs
    all_configs=("${scaling_configs[@]}" "${density_configs[@]}")

    if [[ "${#all_configs[@]}" -eq 0 ]]; then
        log_warn "No configurations selected. Nothing to run."
        return 0
    fi

    log_section "Starting benchmark: ${#all_configs[@]} configurations × ${REPETITIONS} repetitions"

    for rep in $(seq 1 "${REPETITIONS}"); do
        log_section "Repetition ${rep} / ${REPETITIONS}"

        for config in "${all_configs[@]}"; do
            local impl np road_length density
            impl=$(echo "${config}" | cut -d'|' -f1)
            np=$(echo "${config}" | cut -d'|' -f2)
            road_length=$(echo "${config}" | cut -d'|' -f3)
            density=$(echo "${config}" | cut -d'|' -f4)

            if [[ "$(row_already_recorded "${impl}" "${np}" "${road_length}" "${density}" "${rep}")" -gt 0 ]]; then
                log_info "  [SKIP] ${impl} np=${np} N=${road_length} d=${density} rep=${rep}"
                continue
            fi

            printf "  rep=%-2s  impl=%-22s  N=%-10s  d=%-4s  np=%-3s  " \
                "${rep}" "${impl}" "${road_length}" "${density}" "${np}"

            local result ms velocity
            result=$(run_binary "${impl}" "${road_length}" "${density}" "${np}")
            ms=$(echo "${result}" | awk '{print $1}')
            velocity=$(echo "${result}" | awk '{print $2}')

            printf "%s ms  v=%.4f\n" "${ms}" "${velocity}"
            append_result_row "${impl}" "${np}" "${road_length}" "${density}" "${rep}" "${ms}" "${velocity}"
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
                    a[1], a[2], a[3], a[4], sum_ms[k]/cnt[k], sum_v[k]/cnt[k]
            }
        }' "${CSV}" | sort -t'|' -k3,3n -k4,4g -k1,1 -k2,2n \
        | awk -F'|' 'BEGIN {
            printf "%-22s  %-4s  %-12s  %-7s  %9s  %9s\n",
                "impl","np","road_length","density","avg_ms","avg_vel"
            printf "%-22s  %-4s  %-12s  %-7s  %9s  %9s\n",
                "----------------------","----","------------","-------",
                "---------","---------"
        }
        { printf "%-22s  %-4s  %-12s  %-7s  %9.1f  %9.4f\n", $1,$2,$3,$4,$5,$6 }'
    } | tee "${summary}"

    echo ""
    log_ok "Raw averages : ${summary}"
    log_ok "Full dataset : ${CSV}"
}

print_banner() {
    echo -e "${BOLD}"
    echo "================================================================"
    echo "   Traffic Automaton — MPI Benchmark"
    echo "   Machine           : ${MACHINE_FLAG}"
    echo "   Host              : $(hostname 2>/dev/null || echo 'unknown')"
    echo "   Selected impls    : $(selected_impls_string)"
    echo "   N values          : ${N_VALUES[*]}"
    echo "   np counts         : ${ALL_NP_COUNTS[*]}"
    echo "   Measure steps     : ${MEASURE_STEPS}"
    echo "   Repetitions       : ${REPETITIONS}"
    echo "   Bench CPUs        : ${BENCH_CPUS}"
    echo "   Density exp N     : ${DENSITY_EXPERIMENT_N}"
    echo "   Density np        : ${DENSITY_EXPERIMENT_NP[*]}"
    echo "   Loop order        : repetition (outer) → config (inner)"
    echo "   Date              : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================================"
    echo -e "${RESET}"
}

maybe_run_with_inhibit() {
    if [[ "${INTERNAL_RUN}" == true ]]; then
        return 0
    fi

    if [[ "${INHIBIT_SLEEP}" != true ]]; then
        log_warn "Sleep/suspend inhibition is disabled. Skewed results may occur."
        return 0
    fi

    if ! command -v systemd-inhibit &>/dev/null; then
        log_warn "systemd-inhibit not found — machine may suspend during benchmark."
        return 0
    fi

    log_info "Attempting to inhibit sleep/suspend during benchmark..."
    export BENCH_INHIBIT_ACTIVE=1

    exec systemd-inhibit \
        --what=sleep:idle \
        --who="bench_traffic_mpi" \
        --why="MPI Benchmark in progress — do not suspend" \
        --mode=block \
        bash "$(realpath "${BASH_SOURCE[0]}")" --internal-run "$@"
}

main() {
    parse_args "$@"
    maybe_run_with_inhibit "$@"

    mkdir -p "${RESULTS_DIR}" "${BIN_DIR}"

    if ! binaries_are_built; then
        compile_all_binaries
    fi

    log_info "Running serial validation tests..."
    if ! "${BIN_TESTS}" >/dev/null 2>&1; then
        log_error "Serial validation FAILED. Fix the implementation before benchmarking."
        exit 1
    fi
    log_ok "Serial validation passed."

    log_info "Running MPI validator (np=1)..."
    if ! "${MPIRUN}" --oversubscribe -np 1 "${BIN_VALIDATOR}" >/dev/null 2>&1; then
        log_error "MPI validator FAILED (np=1). Fix the MPI implementation before benchmarking."
        exit 1
    fi
    log_ok "MPI validator passed (np=1)."

    setup_csv "${RESULTS_DIR}" "${CSV}" "${CSV_HEADER}"

    sudo -v
    local sudo_keeper_pid
    ( while true; do sudo -nv 2>/dev/null; sleep 55; done ) &
    sudo_keeper_pid=$!

    trap '
        [[ -n "${sudo_keeper_pid:-}" ]] && kill "${sudo_keeper_pid}" 2>/dev/null
        restore_system
    ' EXIT

    optimize_system
    print_banner
    run_benchmark

    echo ""
    print_raw_averages
}

main "$@"