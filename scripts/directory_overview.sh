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
OUTPUT="directory_overview_report_$(date '+%Y%m%d_%H%M%S').csv"
TMP_FILE="/tmp/archive_sizes.$$"

if [ ! -d "$ROOT" ]; then
    echo "Error: Directory does not exist."
    exit 1
fi

echo "Starting directory overview scan..."
echo "Root path: $ROOT and Output file: $OUTPUT"

echo "path,first_level_subdirs,first_level_files,total_size_bytes" > "$OUTPUT"

# --- STEP 1: Pre-calculate full recursive sizes in one pass, du runs once and gives size for every directory ---
echo "Calculating directory sizes (this may take time on large storage)..."
du -b --apparent-size "$ROOT" 2>/dev/null | sort -V > "$TMP_FILE"

TOTAL_DIRS=$(wc -l < "$TMP_FILE")
echo "Total directories detected: $TOTAL_DIRS"

# Convert bytes to human readable size function ---
human_readable() {
    local bytes=$1
    awk -v b="$bytes" 'BEGIN {
        split("B KB MB GB TB PB", units)
        for (i=1; b>=1024 && i<6; i++) b/=1024
        printf "%.2f %s", b, units[i]
    }'
}

# --- STEP 2: Process directories ---
CURRENT=0
TOTAL_DIRS=${TOTAL_DIRS:-0}
while IFS=$'\t' read -r SIZE DIR; do

	CURRENT=$((CURRENT+1))
    PERCENT=$((CURRENT*100/TOTAL_DIRS))

	# Progress output (overwrite same line)
    printf "\rProcessing: %d%% (%d/%d)" "$PERCENT" "$CURRENT" "$TOTAL_DIRS"
	
    # Count first-level subdirectories
    SUBDIR_COUNT=$(find "$DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

    # Count first-level files
    FILE_COUNT=$(find "$DIR" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l)

    HR_SIZE=$(human_readable "$SIZE")

    echo "\"$DIR\",$SUBDIR_COUNT,$FILE_COUNT,\"$HR_SIZE\"" >> "$OUTPUT"

done < "$TMP_FILE"

rm -f "$TMP_FILE"

echo "Directory overview report succesfully created: $OUTPUT"