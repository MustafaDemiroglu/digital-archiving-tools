#!/usr/bin/env bash
###############################################################################
# Script Name: ausbelichtung_rename_and_copy.sh Version:1.2
# Author: Mustafa Demiroglu
#
# Description:
#   This script helps with consistent renaming and copying operations in deep
#   folder structures. It works under Linux, macOS, and WSL (Windows Subsystem
#   for Linux). The script is intended to be *simple, portable, and easy to use*.
#
# Features:
#   - Verbose mode (-v| --verbose): Print detailed information about every operation
#   - Dry run mode (-n| --dry_run): Simulate actions without making changes
#   - Parallel execution (-p| --parallel): Use xargs -P for faster execution
#   - Logging: After each run, a log file is created: log_rename_and_copy_YYYYMMDD.txt
#   - Interactive selection: The user can choose which processes (1, 2, 3, or all)
#     should be executed
#
# Operations:
#   1) Pad lowest-level folder names to 5 digits.
#   2) Pad file numbers in lowest-level folder files to 5 digits.
#   3) Copy a reference test image into each lowest-level folder and rename it.
#
# Usage:
#   ./rename_and_copy.sh -d /path/to/root [options]
#
# Options:
#   -d <dir>		Root directory where operations should be performed
#   -v, --verbose	Verbose mode
#   -n, --dry_run	Dry run mode (simulate without changes)
#   -p, --parallel	Parallel execution (xargs -P)
#   -h, --help  	Show this help message
#
# Example:
#   ./rename_and_copy.sh -d ./data -v
#   ./rename_and_copy.sh -d ./data -p -n
###############################################################################

# ----------------------------- CONFIGURATION ---------------------------------

TESTCHART="/media/cepheus/ingest/testcharts_bestandsblatt/_0000.jpg"
SCRIPT_NAME=$(basename "$0")
DATE_TAG=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="log_${SCRIPT_NAME%.*}_${DATE_TAG}.txt"

VERBOSE=false
DRY_RUN=false
PARALLEL=false
ROOT_DIR=""

# ----------------------------- HELPER FUNCTIONS ------------------------------

show_help() {
    grep '^#' "$0" | sed -E 's/^# ?//'
    exit 0
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

vlog() {
    $VERBOSE && echo "[INFO] $*"
}

run_cmd() {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

ask_root_dir() {
    if [ -z "$ROOT_DIR" ]; then
        echo "Please provide the root directory where operations should be performed."
        echo "Usage: $SCRIPT_NAME -d /path/to/root"
        read -rp "Enter root directory path: " ROOT_DIR
    fi
    if [ ! -d "$ROOT_DIR" ]; then
        echo "Error: '$ROOT_DIR' is not a valid directory!"
        exit 1
    fi
}

ask_process_selection() {
    echo "Which process do you want to run?"
    echo "  1) Rename lowest-level folder names (pad to 5 digits)"
    echo "  2) Rename file numbers (pad to 5 digits)"
    echo "  3) Copy reference testchart into folders"
    echo "  4) All processes (1 → 2 → 3)"
    read -rp "Enter choice (1/2/3/4): " PROCESS_CHOICE
}

pad_number() {
    printf "%05d" "$1"
}

get_lowest_dirs() {
    find "$ROOT_DIR" -type d -links 2
}

# ----------------------------- PROCESS 1 -------------------------------------

process1_single() {
    dir="$1"
    base=$(basename "$dir")
    parent=$(dirname "$dir")
    if [[ "$base" =~ ^[0-9]+$ ]]; then
        padded=$(pad_number "$base")
        if [ "$base" != "$padded" ]; then
            run_cmd mv "$dir" "$parent/$padded"
            log "Renamed folder: $dir → $parent/$padded"
        fi
    fi
}

process1() {
    vlog "Process 1: Renaming lowest-level folders"
    if $PARALLEL; then
        get_lowest_dirs | xargs -n1 -P"$(nproc 2>/dev/null || echo 4)" -I{} bash -c 'process1_single "$@"' _ {}
    else
        get_lowest_dirs | while read -r dir; do
            process1_single "$dir"
        done
    fi
}

# ----------------------------- PROCESS 2 -------------------------------------

process2_single() {
    dir="$1"
    for file in "$dir"/*; do
        [ -f "$file" ] || continue
        fname=$(basename "$file")
        if [[ "$fname" =~ (.*_)([0-9]+)(\.[^.]+)$ ]]; then
            prefix="${BASH_REMATCH[1]}"
            num="${BASH_REMATCH[2]}"
            ext="${BASH_REMATCH[3]}"
            padded=$(pad_number "$num")
            newname="$dir/${prefix}${padded}${ext}"
            if [ "$file" != "$newname" ]; then
                run_cmd mv "$file" "$newname"
                log "Renamed file: $file → $newname"
            fi
        fi
    done
}

process2() {
    vlog "Process 2: Renaming files inside lowest-level folders"
    if $PARALLEL; then
        get_lowest_dirs | xargs -n1 -P"$(nproc 2>/dev/null || echo 4)" -I{} bash -c 'process2_single "$@"' _ {}
    else
        get_lowest_dirs | while read -r dir; do
            process2_single "$dir"
        done
    fi
}

# ----------------------------- PROCESS 3 -------------------------------------

process3_single() {
    dir="$1"
    first_file=$(ls "$dir" | sort | head -n1)
    if [ -n "$first_file" ]; then
        if [[ "$first_file" =~ (.*_)([0-9]+)(\.[^.]+)$ ]]; then
            prefix="${BASH_REMATCH[1]}"
            ext="${BASH_REMATCH[3]}"
            newname="$dir/${prefix}00000${ext}"
            run_cmd cp "$TESTCHART" "$newname"
            log "Copied testchart into: $newname"
        fi
    fi
}

process3() {
    vlog "Process 3: Copying testchart into lowest-level folders"
    if [ ! -f "$TESTCHART" ]; then
        echo "Error: Testchart file not found: $TESTCHART"
        exit 1
    fi
    if $PARALLEL; then
        get_lowest_dirs | xargs -n1 -P"$(nproc 2>/dev/null || echo 4)" -I{} bash -c 'process3_single "$@"' _ {}
    else
        get_lowest_dirs | while read -r dir; do
            process3_single "$dir"
        done
    fi
}

# ----------------------------- MAIN LOGIC ------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) ROOT_DIR="$2"; shift 2 ;;
        -v| --verbose) VERBOSE=true; shift ;;
        -n| --dry_run) DRY_RUN=true; shift ;;
        -p| --parallel) PARALLEL=true; shift ;;
        -h| --help) show_help ;;
        *) echo "Unknown option: $1"; show_help ;;
    esac
done

ask_root_dir
ask_process_selection

case "$PROCESS_CHOICE" in
    1) process1 ;;
    2) process2 ;;
    3) process3 ;;
    4)
        process1
        process2
        process3
        ;;
    *) echo "Invalid choice" && exit 1 ;;
esac

log "Script finished successfully."
echo "Log written to $LOG_FILE"
