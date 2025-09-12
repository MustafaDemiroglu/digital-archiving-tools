#!/usr/bin/env bash
###############################################################################
# Script Name: find_and_delete_empty_dirs.sh
# Version: 1.1
# Author: Mustafa Demiroglu
#
# Description:
#   This script scans a given directory (including all its subdirectories)
#   and identifies all empty directories (directories with no files or subfolders).
#   It prints the list of empty directories to the terminal and then asks the user
#   whether they want to delete them.
#
# Features:
#   1. If no directory is provided as an argument, the script will ask the user
#      for the directory path.
#   2. Handles directory names with spaces or special characters safely.
#   3. If confirmed, deletes all empty directories and saves the deleted
#      directory paths into a CSV file.
#   4. If not confirmed, nothing is deleted and the user is informed.
#
# Output:
#   - deleted_empty_dirs_<DATE>.csv : List of deleted directories
#
# Example Usage:
#   ./find_and_delete_empty_dirs.sh /path/to/search
#
###############################################################################

set -euo pipefail

# Current date for CSV file
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
CSV_FILE="deleted_empty_dirs_${DATE}.csv"

# Function to ask for input if no argument provided
ask_for_input() {
    local var_name=$1
    local prompt=$2
    local value=${!var_name:-}

    if [ -z "$value" ]; then
        read -r -p "$prompt: " value
    fi
    echo "$value"
}

# Get directory from argument or ask user
SEARCH_DIR=${1:-}
SEARCH_DIR=$(ask_for_input SEARCH_DIR "Enter the directory path to scan")

# Check if directory exists
if [ ! -d "$SEARCH_DIR" ]; then
    echo "[ERROR] Directory not found: $SEARCH_DIR"
    exit 1
fi

echo "-------------------------------------------------"
echo "Scanning for empty directories under: $SEARCH_DIR"
echo "-------------------------------------------------"

# Find empty directories
mapfile -d '' EMPTY_DIRS < <(find "$SEARCH_DIR" -type d -empty -print0)

if [ ${#EMPTY_DIRS[@]} -eq 0 ]; then
    echo "No empty directories found."
    exit 0
fi

echo "Empty directories found:"
printf '%s\n' "${EMPTY_DIRS[@]}"

echo "-------------------------------------------------"
read -r -p "Do you want to delete all these empty directories? (y/n): " CONFIRM

if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Deleting empty directories..."
    echo "Deleted_Directory" > "$CSV_FILE"
    for dir in "${EMPTY_DIRS[@]}"; do
        if rmdir "$dir" 2>/dev/null; then
            echo "$dir" >> "$CSV_FILE"
        else
            echo "[WARNING] Could not delete: $dir"
        fi
    done
    echo "-------------------------------------------------"
    echo "Deletion complete."
    echo "Deleted directories have been saved in: $CSV_FILE"
else
    echo "Operation canceled by user. No directories were deleted."
fi
