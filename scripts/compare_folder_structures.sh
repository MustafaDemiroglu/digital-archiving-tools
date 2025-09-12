#!/usr/bin/env bash
###############################################################################
# Script Name: compare_folder_structures.sh
# Version 1.0
# Author: Mustafa Demiroglu
#
# Description:
#   This script compares two large folder structures to identify missing
#   directories. It is designed for use on Linux, macOS, and Windows (via WSL
#   or Git Bash). The goal is to ensure that both folder trees are identical
#   in structure. Any missing directories will be reported in a CSV file.
#
# Features:
#   1. Asks user for input directories if not provided as arguments.
#   2. Scans the "reference" directory tree and checks if all subdirectories
#      exist in the "target" directory tree.
#   3. Handles directories with spaces or special characters.
#   4. Logs all errors (unreadable/inaccessible folders) and script execution
#      summary in a log file.
#   5. Saves missing directories (not found in target tree) into a CSV file.
#
# Output:
#   - result_compare_<DATE>.log : Log file with errors and summary
#   - lost_compare_<DATE>.csv   : CSV file with missing directories
#
# Example Usage:
#   ./compare_folder_structures.sh /media/archive/public/www /media/cepheus
#
###############################################################################

set -euo pipefail

# Get current date for filenames
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
SCRIPT_NAME=$(basename "$0" .sh)
LOG_FILE="result_${SCRIPT_NAME}_${DATE}.log"
CSV_FILE="lost_${SCRIPT_NAME}_${DATE}.csv"

# Function to ask for input if not provided
ask_for_input() {
    local var_name=$1
    local prompt=$2
    local value=${!var_name:-}

    if [ -z "$value" ]; then
        read -r -p "$prompt: " value
    fi
    echo "$value"
}

# Get directories from arguments or ask user
REFERENCE_DIR=${1:-}
TARGET_DIR=${2:-}

REFERENCE_DIR=$(ask_for_input REFERENCE_DIR "Enter path to reference directory")
TARGET_DIR=$(ask_for_input TARGET_DIR "Enter path to target directory")

echo "Reference directory: $REFERENCE_DIR"
echo "Target directory:    $TARGET_DIR"
echo "Logs will be saved in: $LOG_FILE"
echo "Missing directories will be saved in: $CSV_FILE"
echo "-------------------------------------------------"

# Initialize log and CSV
echo "Script started at $(date)" > "$LOG_FILE"
echo "Reference: $REFERENCE_DIR" >> "$LOG_FILE"
echo "Target:    $TARGET_DIR" >> "$LOG_FILE"
echo "-------------------------------------------------" >> "$LOG_FILE"
echo "Missing_Directory" > "$CSV_FILE"

# Check both directories exist
if [ ! -d "$REFERENCE_DIR" ]; then
    echo "[ERROR] Reference directory not found: $REFERENCE_DIR" | tee -a "$LOG_FILE"
    exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
    echo "[ERROR] Target directory not found: $TARGET_DIR" | tee -a "$LOG_FILE"
    exit 1
fi

# Traverse all directories in reference
# -print0 and read -d '' ensure spaces in names are handled safely
while IFS= read -r -d '' dir; do
    # Relative path from reference root
    rel_path="${dir#$REFERENCE_DIR/}"

    # Skip if rel_path is empty (the root itself)
    [ -z "$rel_path" ] && continue

    target_path="$TARGET_DIR/$rel_path"

    if [ ! -d "$target_path" ]; then
        echo "$rel_path" >> "$CSV_FILE"
    fi
done < <(find "$REFERENCE_DIR" -type d -print0 2>>"$LOG_FILE")

echo "-------------------------------------------------" >> "$LOG_FILE"
echo "Script finished at $(date)" >> "$LOG_FILE"
echo "Results:"
echo " - Log file: $LOG_FILE"
echo " - Missing directories: $CSV_FILE"