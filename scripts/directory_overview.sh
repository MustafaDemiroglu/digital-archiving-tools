#!/usr/bin/env bash
###############################################################################
# Script Name : directory_overview.sh
# Purpose     : High-performance archive directory overview (single traversal)
#
# What this script does:
#   - Scans a root directory only once.
#   - Calculates:
#       1. First-level subdirectory count
#       2. First-level file count
#       3. Full recursive size in bytes
#   - Works for very large archive environments.
###############################################################################

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /path/to/root_directory"
    exit 1
fi

ROOT="$1"
OUTPUT="directory_overview_report.csv_$(date '+%Y%m%d_%H%M%S')"

if [ ! -d "$ROOT" ]; then
    echo "Error: Directory does not exist."
    exit 1
fi

echo "path,first_level_subdirs,first_level_files,total_size_bytes" > "$OUTPUT"

# --- STEP 1: Pre-calculate full recursive sizes in one pass ---
# du runs once and gives size for every directory
du -b --apparent-size "$ROOT" 2>/dev/null | sort -V > /tmp/archive_sizes.$$ 

# --- STEP 2: Convert bytes to human readable ---
human_readable() {
    local bytes=$1
    awk -v b="$bytes" 'BEGIN {
        split("B KB MB GB TB PB", units)
        for (i=1; b>=1024 && i<6; i++) b/=1024
        printf "%.2f %s", b, units[i]
    }'
}

# --- STEP 3: Process directories ---
while IFS=$'\t' read -r SIZE DIR; do

    # Count first-level subdirectories
    SUBDIR_COUNT=$(find "$DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

    # Count first-level files
    FILE_COUNT=$(find "$DIR" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l)

    HR_SIZE=$(human_readable "$SIZE")

    echo "\"$DIR\",$SUBDIR_COUNT,$FILE_COUNT,\"$HR_SIZE\"" >> "$OUTPUT"

done < "$TMP_FILE"

rm -f "$TMP_FILE"

echo "Archive-level report created: $OUTPUT"