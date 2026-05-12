#!/usr/bin/env bash
# =============================================================================
# bench_profiling.sh  --  CPU and memory profiling of the sequential
#                         traffic automaton implementation.
#
# Tools used:
#   gprof         : time per function ( -fno-inline -pg to prevent
#                   inlining from silencing hot functions)
#   perf stat     : hardware counters (L1, LLC, TLB, branch) repeated
#                   PERF_STAT_REPEATS times (-r)
#   perf record   : sampling-based hot-spot profiling with call-graph (-g)
#   valgrind      : heap memory (massif) and cache simulation (cachegrind)
#                   — only for N <= VALGRIND_MAX_N to keep runtime feasible
#
# The binary outputs "wall_time_ms avg_velocity" on stdout.
# TIMING_RUNS independent executions are performed per size; the first is
# discarded (cache warm-up).  Mean, std and mean velocity are reported.
#
# Throughput is expressed in million cells per second:
#   Mcells/s = (N × MEASURE_STEPS) / (mean_ms / 1000) / 1e6
#
# Usage:
#   ./tests/benchmarks/bench_profiling.sh [--force|-f]
#
# Options:
#   --force, -f   Overwrite existing raw reports and CSV rows.
#
# Output:
#   tests/<MACHINE>/results_profiling/data_profiling.csv
#   tests/<MACHINE>/results_profiling/raw/N<size>/
#
# Requires: gcc, gprof, perf (optional), valgrind (optional), python3
# =============================================================================

set -euo pipefail
export LC_NUMERIC=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

source "tests/bench_utils.sh"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
FORCE=0
for arg in "$@"; do
    case "${arg}" in
        --force|-f) FORCE=1 ;;
        *) log_warn "Unknown argument: ${arg}" ;;
    esac
done

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
MACHINE="${MACHINE_FLAG:-machine1}"

SRC_FILES="src/road.c src/simulation.c src/cli_args.c src/timing.c src/seq_main.c"
BIN_DIR="bin"
RESULTS_DIR="tests/${MACHINE}/results_profiling"
CSV_FILE="${RESULTS_DIR}/data_profiling.csv"

# Binary compiled for perf/valgrind (debug info, no instrumentation)
BIN_PERF="${BIN_DIR}/traffic_seq_perf"
# Binary compiled for gprof (instrumented, no inlining)
BIN_GPROF="${BIN_DIR}/traffic_seq_gprof"

# Road lengths to profile.
# Valgrind is only run for sizes up to VALGRIND_MAX_N (50x slowdown).
PROFILE_N_VALUES=(8000 64000 500000 2000000)
VALGRIND_MAX_N=500000

# Fixed density for all profiling runs.
PROFILE_DENSITY="0.50"

# Steps measured by the binary (warmup excluded from timing).
MEASURE_STEPS=1000

# Independent timing executions per size (first is discarded as warm-up).
TIMING_RUNS=10

# Repetitions passed to perf stat -r (averages counters across runs).
PERF_STAT_REPEATS=1

CSV_HEADER="road_length,density,time_mean_ms,time_std_ms,avg_velocity,\
throughput_mcells_s,\
cycles,instructions,ipc,\
cache_refs,cache_misses,cache_miss_pct,\
l1_loads,l1_misses,l1_miss_pct,\
LLC_loads,LLC_misses,LLC_miss_pct,\
dTLB_loads,dTLB_misses,dTLB_miss_pct,\
branch_instructions,branch_misses,branch_miss_pct,\
peak_heap_mb"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

warmup_ceiling_for() {
    local n="$1"
    local c=$(( n / 10 ))
    [[ "${c}" -lt 2000 ]] && c=2000
    echo "${c}"
}

should_skip() {
    local file="$1"
    if [[ "${FORCE}" -eq 1 ]]; then
        [[ -f "${file}" ]] && log_info "  [FORCE] Overwriting: ${file}"
        rm -f "${file}"
        return 1
    fi
    if [[ -s "${file}" ]]; then
        log_info "  [SKIP] Already exists: $(basename "${file}")"
        return 0
    fi
    [[ -f "${file}" ]] && rm -f "${file}"
    return 1
}

already_done() {
    local n="$1"
    [[ "${FORCE}" -eq 1 ]] && echo 0 && return
    awk -F',' -v s="${n}" 'NR>1 && $1==s { found=1 } END { print found+0 }' \
        "${CSV_FILE}" 2>/dev/null
}

perf_extract() {
    local file="$1" keyword="$2"
    [[ ! -s "${file}" ]] && echo "0" && return
    grep -iE "^[[:space:]]*[0-9,].*${keyword}" "${file}" \
        | grep -v "^#" \
        | head -1 \
        | awk '{gsub(",", "", $1); printf "%d", $1+0}' \
        || echo "0"
}

compute_ratio() {
    local num="$1" den="$2" decimals="${3:-4}"
    python3 -c "
n, d = int('${num}' or 0), int('${den}' or 1)
fmt = f'{{:.${decimals}f}}'
print(fmt.format(n / d * 100) if d > 0 else '0.' + '0'*${decimals})
"
}

parse_peak_mb() {
    local file="$1"
    [[ ! -s "${file}" ]] && echo "0.000" && return
    awk '
    /^-+$/ { in_table=1; next }
    in_table && /^[[:space:]]*[0-9]/ {
        gsub(",", "")
        if ($4+0 > peak) peak = $4+0
    }
    END { printf "%.3f", peak / 1024 / 1024 }
    ' "${file}"
}

# ---------------------------------------------------------------------------
# Compilation
# ---------------------------------------------------------------------------
compile_binaries() {
    log_section "Compiling profiling binaries"
    mkdir -p "${BIN_DIR}"

    if [[ "${FORCE}" -eq 1 ]] || [[ ! -x "${BIN_PERF}" ]]; then
        local cmd="gcc -g -std=c11 -D_POSIX_C_SOURCE=200809L -Iinclude \
-Wno-unknown-pragmas ${SRC_FILES} -o ${BIN_PERF} -lm"
        log_info "  perf/valgrind binary: ${cmd}"
        eval "${cmd}" && log_ok "${BIN_PERF}" || { log_error "Compilation failed"; exit 1; }
    else
        log_info "  Already compiled: ${BIN_PERF}"
    fi

    # -fno-inline prevents the compiler from merging simulation_step and
    # compute_next_generation into the caller, which would make gprof report
    # 100% of time in main() and hide the real hot function.
    if [[ "${FORCE}" -eq 1 ]] || [[ ! -x "${BIN_GPROF}" ]]; then
        local cmd="gcc -fno-inline -g  -pg -std=c11 -D_POSIX_C_SOURCE=200809L \
-Iinclude -Wno-unknown-pragmas ${SRC_FILES} -o ${BIN_GPROF} -lm"
        log_info "  gprof binary: ${cmd}"
        eval "${cmd}" && log_ok "${BIN_GPROF}" || { log_error "Compilation failed"; exit 1; }
    else
        log_info "  Already compiled: ${BIN_GPROF}"
    fi
}

# ---------------------------------------------------------------------------
# Timing  (TIMING_RUNS runs, first discarded as warm-up)
# ---------------------------------------------------------------------------
run_timing_multi() {
    local n="$1" raw_dir="$2"
    local out_ms="${raw_dir}/timing_ms.txt"
    local out_vel="${raw_dir}/timing_vel.txt"
    should_skip "${out_ms}" && return

    log_info "  timing (${TIMING_RUNS} runs, 1 warm-up discarded) N=${n}"
    local warmup
    warmup=$(warmup_ceiling_for "${n}")

    # Warm-up run: discarded
    "${BIN_PERF}" "${n}" "${PROFILE_DENSITY}" "${warmup}" "${MEASURE_STEPS}" \
        > /dev/null 2>&1 || true

    rm -f "${out_ms}" "${out_vel}"
    for _ in $(seq 1 "${TIMING_RUNS}"); do
        local output
        output=$("${BIN_PERF}" "${n}" "${PROFILE_DENSITY}" "${warmup}" "${MEASURE_STEPS}" \
            2>/dev/null) || output="0.000 0.000000"
        echo "${output}" | awk '{print $1}' >> "${out_ms}"
        echo "${output}" | awk '{print $2}' >> "${out_vel}"
    done
}

measure_timing_stats() {
    local raw_dir="$1"
    local ms_file="${raw_dir}/timing_ms.txt"
    local vel_file="${raw_dir}/timing_vel.txt"

    [[ ! -s "${ms_file}" ]] && echo "0 0 0" && return

    python3 - "${ms_file}" "${vel_file}" <<'EOF'
import sys, statistics

def read_floats(path):
    vals = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line:
                    try: vals.append(float(line))
                    except ValueError: pass
    except FileNotFoundError:
        pass
    return vals

ms_vals  = read_floats(sys.argv[1])
vel_vals = read_floats(sys.argv[2]) if len(sys.argv) > 2 else []

if not ms_vals:
    print("0 0 0")
else:
    mean_ms  = statistics.mean(ms_vals)
    std_ms   = statistics.stdev(ms_vals) if len(ms_vals) > 1 else 0.0
    mean_vel = statistics.mean(vel_vals) if vel_vals else 0.0
    print(f"{mean_ms:.3f} {std_ms:.3f} {mean_vel:.6f}")
EOF
}

compute_throughput_mcells_s() {
    local n="$1" mean_ms="$2"
    python3 -c "
n, ms = int('${n}'), float('${mean_ms}')
steps = ${MEASURE_STEPS}
if ms <= 0: print('0.000000')
else: print(f'{n * steps / (ms / 1000) / 1e6:.6f}')
"
}

# ---------------------------------------------------------------------------
# gprof
# ---------------------------------------------------------------------------
run_gprof() {
    local n="$1" raw_dir="$2"
    local out="${raw_dir}/gprof_report.txt"
    should_skip "${out}" && return

    log_info "  gprof N=${n}"
    local warmup
    warmup=$(warmup_ceiling_for "${n}")

    "${BIN_GPROF}" "${n}" "${PROFILE_DENSITY}" "${warmup}" "${MEASURE_STEPS}" \
        > /dev/null 2>&1 || true

    if [[ -f gmon.out ]]; then
        gprof "${BIN_GPROF}" gmon.out > "${out}" 2>&1 || log_warn "gprof failed N=${n}"
        rm -f gmon.out
    else
        log_warn "gmon.out not generated for N=${n}"
        touch "${out}"
    fi
}

# ---------------------------------------------------------------------------
# perf stat
# ---------------------------------------------------------------------------
run_perf() {
    local n="$1" raw_dir="$2"
    local out="${raw_dir}/perf_stat.txt"
    should_skip "${out}" && return

    log_info "  perf stat N=${n}"
    if ! command -v perf &>/dev/null; then
        log_warn "  perf not found — skipping hardware counters"
        touch "${out}"; return
    fi

    local warmup
    warmup=$(warmup_ceiling_for "${n}")

    perf stat \
        -r "${PERF_STAT_REPEATS}" \
        -e cycles,instructions,\
cache-references,cache-misses,\
L1-dcache-loads,L1-dcache-load-misses,\
LLC-loads,LLC-load-misses,\
dTLB-loads,dTLB-load-misses,\
branch-instructions,branch-misses \
        -o "${out}" \
        "${BIN_PERF}" "${n}" "${PROFILE_DENSITY}" "${warmup}" "${MEASURE_STEPS}" \
        > /dev/null 2>&1 || log_warn "perf stat failed N=${n}"
}

# ---------------------------------------------------------------------------
# perf record
# ---------------------------------------------------------------------------
run_perf_record() {
    local n="$1" raw_dir="$2"
    local out="${raw_dir}/perf_record_report.txt"
    should_skip "${out}" && return

    log_info "  perf record N=${n}"
    if ! command -v perf &>/dev/null; then
        touch "${out}"; return
    fi

    local warmup
    warmup=$(warmup_ceiling_for "${n}")

    perf record -g -F 999 \
        -o "${raw_dir}/perf.data" \
        "${BIN_PERF}" "${n}" "${PROFILE_DENSITY}" "${warmup}" "${MEASURE_STEPS}" \
        > /dev/null 2>&1 || log_warn "perf record failed N=${n}"

    perf report --stdio --no-children \
        -i "${raw_dir}/perf.data" > "${out}" 2>&1 || true

    rm -f "${raw_dir}/perf.data"
}

# ---------------------------------------------------------------------------
# valgrind — only for N <= VALGRIND_MAX_N
# ---------------------------------------------------------------------------
run_massif() {
    local n="$1" raw_dir="$2"
    local out="${raw_dir}/massif_report.txt"

    if (( n > VALGRIND_MAX_N )); then
        log_info "  massif SKIPPED (N=${n} > ${VALGRIND_MAX_N})"
        touch "${out}"; return
    fi
    should_skip "${out}" && return

    log_info "  valgrind massif N=${n}"
    if ! command -v valgrind &>/dev/null; then
        log_warn "  valgrind not found — skipping"
        touch "${out}"; return
    fi

    local warmup
    warmup=$(warmup_ceiling_for "${n}")

    valgrind --tool=massif \
        --massif-out-file="${raw_dir}/massif.out" \
        "${BIN_PERF}" "${n}" "${PROFILE_DENSITY}" "${warmup}" "${MEASURE_STEPS}" \
        > /dev/null 2>&1 || log_warn "massif failed N=${n}"

    ms_print "${raw_dir}/massif.out" > "${out}" 2>&1 || true
    rm -f "${raw_dir}/massif.out"
}

run_cachegrind() {
    local n="$1" raw_dir="$2"
    local out="${raw_dir}/cachegrind_report.txt"

    if (( n > VALGRIND_MAX_N )); then
        log_info "  cachegrind SKIPPED (N=${n} > ${VALGRIND_MAX_N})"
        touch "${out}"; return
    fi
    should_skip "${out}" && return

    log_info "  valgrind cachegrind N=${n}"
    if ! command -v valgrind &>/dev/null; then
        touch "${out}"; return
    fi

    local warmup
    warmup=$(warmup_ceiling_for "${n}")

    valgrind --tool=cachegrind \
        --cachegrind-out-file="${raw_dir}/cachegrind.out" \
        "${BIN_PERF}" "${n}" "${PROFILE_DENSITY}" "${warmup}" "${MEASURE_STEPS}" \
        > /dev/null 2>&1 || log_warn "cachegrind failed N=${n}"

    cg_annotate "${raw_dir}/cachegrind.out" > "${out}" 2>&1 || true
    rm -f "${raw_dir}/cachegrind.out"
}

# ---------------------------------------------------------------------------
# Assemble CSV row for one N
# ---------------------------------------------------------------------------
profile_size() {
    local n="$1"
    local raw_dir="${RESULTS_DIR}/raw/N${n}"

    if [[ "$(already_done "${n}")" -gt 0 ]]; then
        log_info "[SKIP] N=${n} already in CSV (use --force to re-run)"
        return
    fi

    log_section "Profiling N=${n}"
    mkdir -p "${raw_dir}"

    run_timing_multi "${n}" "${raw_dir}" || log_warn "timing failed N=${n}"
    run_gprof        "${n}" "${raw_dir}" || log_warn "gprof failed N=${n}"
    run_perf         "${n}" "${raw_dir}" || log_warn "perf stat failed N=${n}"
    run_perf_record  "${n}" "${raw_dir}" || log_warn "perf record failed N=${n}"
    run_massif       "${n}" "${raw_dir}" || log_warn "massif failed N=${n}"
    run_cachegrind   "${n}" "${raw_dir}" || log_warn "cachegrind failed N=${n}"

    # --- timing stats ---
    local stats
    stats=$(measure_timing_stats "${raw_dir}") || stats="0 0 0"
    local time_mean_ms time_std_ms avg_velocity
    time_mean_ms=$(  echo "${stats}" | awk '{print $1}')
    time_std_ms=$(   echo "${stats}" | awk '{print $2}')
    avg_velocity=$(  echo "${stats}" | awk '{print $3}')

    local throughput
    throughput=$(compute_throughput_mcells_s "${n}" "${time_mean_ms}") || throughput="0"

    # --- hardware counters ---
    local perf_file="${raw_dir}/perf_stat.txt"

    local cycles instructions ipc
    cycles=$(      perf_extract "${perf_file}" "cycles")
    instructions=$(perf_extract "${perf_file}" "instructions")
    ipc=$(python3 -c "
c, i = int('${cycles}' or 0), int('${instructions}' or 0)
print(f'{i/c:.4f}' if c > 0 else '0.0000')
")

    local cache_refs cache_misses cache_miss_pct
    cache_refs=$(  perf_extract "${perf_file}" "cache-references")
    cache_misses=$(perf_extract "${perf_file}" "cache-misses")
    cache_miss_pct=$(compute_ratio "${cache_misses}" "${cache_refs}")

    local l1_loads l1_misses l1_miss_pct
    l1_loads=$( perf_extract "${perf_file}" "L1-dcache-loads")
    l1_misses=$(perf_extract "${perf_file}" "L1-dcache-load-misses")
    l1_miss_pct=$(compute_ratio "${l1_misses}" "${l1_loads}")

    local llc_loads llc_misses llc_miss_pct
    llc_loads=$( perf_extract "${perf_file}" "LLC-loads")
    llc_misses=$(perf_extract "${perf_file}" "LLC-load-misses")
    llc_miss_pct=$(compute_ratio "${llc_misses}" "${llc_loads}")

    local dtlb_loads dtlb_misses dtlb_miss_pct
    dtlb_loads=$( perf_extract "${perf_file}" "dTLB-loads")
    dtlb_misses=$(perf_extract "${perf_file}" "dTLB-load-misses")
    dtlb_miss_pct=$(compute_ratio "${dtlb_misses}" "${dtlb_loads}")

    local branch_instructions branch_misses branch_miss_pct
    branch_instructions=$(perf_extract "${perf_file}" "branch-instructions")
    branch_misses=$(      perf_extract "${perf_file}" "branch-misses")
    branch_miss_pct=$(compute_ratio "${branch_misses}" "${branch_instructions}")

    local peak_heap_mb
    peak_heap_mb=$(parse_peak_mb "${raw_dir}/massif_report.txt") || peak_heap_mb="0.000"

    # Remove existing row if --force
    if [[ "${FORCE}" -eq 1 ]] && [[ -f "${CSV_FILE}" ]]; then
        local tmp
        tmp=$(mktemp)
        awk -F',' -v s="${n}" '$1!=s' "${CSV_FILE}" > "${tmp}"
        mv "${tmp}" "${CSV_FILE}"
    fi

    printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "${n}" "${PROFILE_DENSITY}" \
        "${time_mean_ms}" "${time_std_ms}" "${avg_velocity}" "${throughput}" \
        "${cycles}" "${instructions}" "${ipc}" \
        "${cache_refs}" "${cache_misses}" "${cache_miss_pct}" \
        "${l1_loads}" "${l1_misses}" "${l1_miss_pct}" \
        "${llc_loads}" "${llc_misses}" "${llc_miss_pct}" \
        "${dtlb_loads}" "${dtlb_misses}" "${dtlb_miss_pct}" \
        "${branch_instructions}" "${branch_misses}" "${branch_miss_pct}" \
        "${peak_heap_mb}" >> "${CSV_FILE}"
    sync

    log_ok "N=${n}: ${time_mean_ms} ± ${time_std_ms} ms | v=${avg_velocity} | \
${throughput} Mcells/s | L1 miss ${l1_miss_pct}% | LLC miss ${llc_miss_pct}% | \
heap ${peak_heap_mb} MB"
}

# ---------------------------------------------------------------------------
# Banner / summary
# ---------------------------------------------------------------------------
print_banner() {
    echo -e "${BOLD}"
    echo "================================================================"
    echo "   Traffic Automaton — CPU & Memory Profiling"
    echo "   Machine      : ${MACHINE}"
    echo "   N values     : ${PROFILE_N_VALUES[*]}"
    echo "   Density      : ${PROFILE_DENSITY}"
    echo "   Measure steps: ${MEASURE_STEPS}"
    echo "   Timing runs  : ${TIMING_RUNS} (+ 1 warm-up discarded)"
    echo "   perf repeats : ${PERF_STAT_REPEATS}"
    echo "   Valgrind max : N <= ${VALGRIND_MAX_N}"
    echo "   Binaries     : ${BIN_PERF} | ${BIN_GPROF}"
    echo "   Output       : ${CSV_FILE}"
    echo "   Mode         : $([ "${FORCE}" -eq 1 ] && echo 'FORCE' || echo 'incremental')"
    echo "   GCC          : $(gcc --version | head -1)"
    echo "   Date         : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "================================================================"
    echo -e "${RESET}"
}

print_summary() {
    log_section "Results"
    [[ -s "${CSV_FILE}" ]] && column -t -s',' "${CSV_FILE}" || true
    log_ok "CSV     : ${CSV_FILE}"
    log_ok "Raw data: ${RESULTS_DIR}/raw/"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
    mkdir -p "${RESULTS_DIR}" "${BIN_DIR}"
    print_banner
    compile_binaries
    trap restore_system EXIT
    optimize_system
    setup_csv "${RESULTS_DIR}" "${CSV_FILE}" "${CSV_HEADER}"

    for n in "${PROFILE_N_VALUES[@]}"; do
        profile_size "${n}"
    done

    print_summary
}

main