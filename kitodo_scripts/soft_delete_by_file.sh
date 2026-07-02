#!/bin/bash
# see library for parameters

set -euo pipefail

# Source Kitodo library
if ! source "$(dirname "${0}")/lib_hla_kitodo.sh"; then
    echo "Failed to include library file!"
    exit 5
fi

search_folder_vze

log_info()  { echo "[INFO]  $(date '+%F %T') - $1"; }
log_error() { echo "[ERROR] $(date '+%F %T') - $1"; }

PYTHON_SCRIPT="$(dirname "${0}")/soft_delete_by_file.py"

if [[ ! -f "${PYTHON_SCRIPT}" ]]; then
    log_error "Python script not found: ${PYTHON_SCRIPT}"
    exit 3
fi

log_info "Starting database soft delete..."

python3 "${PYTHON_SCRIPT}" "$@"

exit_code=$?

if [[ "${exit_code}" -ne 0 ]]; then
    log_error "Database soft delete failed (exit code ${exit_code})."
    exit "${exit_code}"
fi

log_info "Database soft delete finished successfully."

exit 0