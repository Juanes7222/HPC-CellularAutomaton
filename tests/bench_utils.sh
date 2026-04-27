#!/usr/bin/env bash
# =============================================================================
# bench_utils.sh  --  Shared utilities for HPC benchmark scripts
#
# Source this file from any benchmark script:
#   source "$(dirname "$0")/bench_utils.sh"
#
# Provides:
#   - Color variables
#   - Logging functions  (log_info, log_ok, log_warn, log_error, log_section)
#   - optimize_system    (governor + turbo + cache + ASLR)
#   - restore_system     (undo optimize_system on EXIT)
#   - setup_csv          (mkdir -p + write header if new file)
# =============================================================================


RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_section() { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

optimize_system() {
    log_section "Optimizing system"

    if sudo cpupower frequency-set -g performance > /dev/null 2>&1; then
        log_ok "CPU governor: performance"
    else
        log_warn "Could not set CPU governor (cpupower not available?)"
    fi

    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo > /dev/null
        log_ok "Intel Turbo Boost: disabled"
    fi

    if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        echo 0 | sudo tee /sys/devices/system/cpu/cpufreq/boost > /dev/null
        log_ok "AMD Turbo Boost: disabled"
    fi

    sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
    log_ok "Page cache: cleared"

    echo 0 | sudo tee /proc/sys/kernel/randomize_va_space > /dev/null
    log_ok "ASLR: disabled"

    local paranoid_orig
    paranoid_orig=$(cat /proc/sys/kernel/perf_event_paranoid)
    export PERF_PARANOID_ORIG="${paranoid_orig}"
    echo -1 | sudo tee /proc/sys/kernel/perf_event_paranoid > /dev/null
    log_ok "perf_event_paranoid: -1 (full hardware counter access)"
}

restore_system() {
    log_section "Restoring system"

    sudo cpupower frequency-set -g powersave > /dev/null 2>&1 || true

    if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
        echo 0 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo > /dev/null
        log_ok "Intel Turbo Boost: restored"
    fi

    if [[ -f /sys/devices/system/cpu/cpufreq/boost ]]; then
        echo 1 | sudo tee /sys/devices/system/cpu/cpufreq/boost > /dev/null
        log_ok "AMD Turbo Boost: restored"
    fi

    echo 2 | sudo tee /proc/sys/kernel/randomize_va_space > /dev/null
    log_ok "ASLR: restored"

    local restore_val="${PERF_PARANOID_ORIG:-2}"
    echo "${restore_val}" | sudo tee /proc/sys/kernel/perf_event_paranoid > /dev/null
    log_ok "perf_event_paranoid: restored to ${restore_val}"

    log_ok "System restored."
}

# ---------------------------------------------------------------------------
# CSV setup
#
# Usage:
#   setup_csv <results_dir> <csv_file> <header_line>
#
# Example:
#   setup_csv "results_cache" "results_cache/data_cache.csv" \
#             "impl,matrix_size,repetition,wall_time_ms"
# ---------------------------------------------------------------------------

setup_csv() {
    local results_dir="$1"
    local csv_file="$2"
    local header="$3"

    mkdir -p "${results_dir}" "${BIN_DIR:-bin}"

    if [[ -f "${csv_file}" ]]; then
        local existing=$(( $(wc -l < "${csv_file}") - 1 ))
        log_warn "Existing CSV detected with ${existing} row(s). Resuming."
    else
        echo "${header}" > "${csv_file}"
        log_ok "CSV created: ${csv_file}"
    fi
}