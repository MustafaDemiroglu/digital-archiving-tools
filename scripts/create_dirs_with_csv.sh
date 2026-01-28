#!/usr/bin/env bash

# SIMPLE CONFIG
CSV_FILE="$1"
LOG_FILE="create_thumbs.log"
BASE_DIR="$(pwd)"

# LOG FUNCTION
log() {
    local level="$1"
    local message="$2"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$level] $message" | tee -a "$LOG_FILE"
}

# CHECK INPUT
if [[ -z "$CSV_FILE" ]]; then
    echo "Usage: $0 <csv_file>"
    exit 1
fi

if [[ ! -f "$CSV_FILE" ]]; then
    log "ERROR" "CSV file not found: $CSV_FILE"
    exit 1
fi

log "INFO" "Script started. CSV file: $CSV_FILE"

# READ CSV LINE BY LINE
while IFS= read -r signature || [[ -n "$signature" ]]; do

    # Skip empty lines
    [[ -z "$signature" ]] && continue

    target_dir="$BASE_DIR/$signature/thumbs"

    # Check if directory already exists
    if [[ -d "$target_dir" ]]; then
        log "WARN" "Directory already exists, skipped: $target_dir"
    else
        # Try to create directory
        if mkdir -p "$target_dir"; then
            log "SUCCESS" "Directory created: $target_dir"
        else
            log "ERROR" "Failed to create directory: $target_dir"
        fi
    fi

done < "$CSV_FILE"

log "INFO" "Script finished."