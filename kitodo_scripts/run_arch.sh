#!/bin/bash
set -euo pipefail

# Source Kitodo lib
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file!"
    exit 5
fi

search_folder_vze

log_info()  { echo "[INFO]  $(date '+%F %T') - $1"; }
log_error() { echo "[ERROR] $(date '+%F %T') - $1"; }

# MD5 file from Kitodo
if [[ ! -f "${md5_file}" ]]; then
    log_error "MD5 file not found: ${md5_file}"
    exit 1
fi

log_info "MD5 file detected: ${md5_file}"

# CSV derive
csv_file="${md5_file%.md5}.csv"

if [[ ! -f "${csv_file}" ]]; then
    log_error "CSV file not found next to MD5: ${csv_file}"
    exit 2
fi

log_info "CSV file detected: ${csv_file}"

# SAME DIRECTORY çağırma (doğru yol bu)
MAIN_SCRIPT="$(dirname "${0}")/hstam_architekturzeichnungen_restructure.sh"

if [[ ! -x "${MAIN_SCRIPT}" ]]; then
    log_error "Main script not executable: ${MAIN_SCRIPT}"
    exit 3
fi

log_info "Starting restructuring script..."

"${MAIN_SCRIPT}" "${csv_file}"

exit_code=$?

if [[ "${exit_code}" -ne 0 ]]; then
    log_error "Restructure script failed with exit code ${exit_code}"
    exit "${exit_code}"
fi

log_info "Restructure script completed successfully."

exit 0