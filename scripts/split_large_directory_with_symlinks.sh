#!/usr/bin/env bash
###############################################################################
# Script Name: split_large_directory_with_symlinks.sh
# Version:1.3.1
# Author: Mustafa Demiroglu
# Organisation: HlaDigiTeam
# License: MIT
#
# Purpose:
#   Safely prepare very large archive directories for Windows clients by
#   creating a split directory structure using symbolic links.
#
# Background:
#   Windows clients often cannot browse directories containing more than
#   ~10,000 entries. Linux systems do not have this limitation.
#   Archive folder structures MUST NOT be changed because they are part of
#   official archival records.
#
#   This script:
#     - DOES NOT modify the original archive directory
#     - Creates a *_split directory next to it
#     - Splits first-level subdirectories into groups (default: 9000)
#     - Creates symbolic links for each group
#
# Safety:
#   - Supports --dry-run mode (no changes are made)
#   - Logs ALL actions in every mode
#   - Exits early on structural problems
#
# Usage:
#   split_large_directory_with_symlinks.sh [OPTIONS] <path>
#
# Options:
#   -n, --dry-run     Simulate actions without making changes
#   -v, --verbose     Show detailed processing information
#   -h, --help        Show this help message
#
###############################################################################

set -o errexit
set -o pipefail
set -o nounset

#######################################
# Configuration
#######################################
SPLIT_SIZE=9000
LOG_FILE="./split_large_directory_with_symlinks.log"

#######################################
# Global flags
#######################################
DRY_RUN=false
VERBOSE=false
TARGET_PATH=""

#######################################
# Helper functions
#######################################
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" >> "$LOG_FILE"
}

info() {
    echo "[INFO] $*"
    log "[INFO] $*"
}

verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo "[VERBOSE] $*"
    fi
    log "[VERBOSE] $*"
}

warn() {
    echo "[WARNING] $*" >&2
    log "[WARNING] $*"
}

error_exit() {
    echo "[ERROR] $*" >&2
    log "[ERROR] $*"
    exit 1
}

run_cmd() {
    if [[ "$DRY_RUN" == true ]]; then
        verbose "DRY-RUN: $*"
    else
        verbose "EXECUTE: $*"
        eval "$@"
    fi
}

usage() {
    sed -n '1,120p' "$0"
    exit 0
}

#######################################
# Argument parsing
#######################################
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        -*)
            error_exit "Unknown option: $1"
            ;;
        *)
            TARGET_PATH="$1"
            shift
            ;;
    esac
done

#######################################
# Initial checks
#######################################
[[ -z "$TARGET_PATH" ]] && error_exit "No path provided."

REAL_PATH="$(realpath "$TARGET_PATH" 2>/dev/null || true)"
[[ -z "$REAL_PATH" ]] && error_exit "Provided path does not exist."

[[ ! -d "$REAL_PATH" ]] && error_exit "Provided path is not a directory."

info "Target directory: $REAL_PATH"

if [[ "$DRY_RUN" == true ]]; then
    info "DRY-RUN mode enabled – no changes will be made."
fi

#######################################
# Structural checks
#######################################
FILE_COUNT=$(find "$REAL_PATH" -mindepth 1 -maxdepth 1 -type f | wc -l)
[[ "$FILE_COUNT" -gt 0 ]] && error_exit "Files found at first directory level. Manual correction required."

DIR_COUNT=$(find "$REAL_PATH" -mindepth 1 -maxdepth 1 -type d | wc -l)

if [[ "$DIR_COUNT" -lt 10000 ]]; then
    warn "Only $DIR_COUNT subdirectories found."
    warn "This script is intended for directories with more than 10,000 subdirectories."
    exit 0
fi

info "Found $DIR_COUNT first-level subdirectories."

#######################################
# Step 1: Create full directory list
#######################################
info "Creating natural sorted directory list."

find "$REAL_PATH" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" \
    | sort -V > dirs_all.list

TOTAL_LINES=$(wc -l < dirs_all.list)
log "Total directories listed: $TOTAL_LINES"

#######################################
# Step 2: Split list into parts
#######################################
info "Splitting directory list into chunks of $SPLIT_SIZE."

PART=1
while [[ -s dirs_all.list ]]; do
    head -n "$SPLIT_SIZE" dirs_all.list > "dirs_part_${PART}.list"
    tail -n +"$((SPLIT_SIZE + 1))" dirs_all.list > dirs_all.tmp || true
    mv dirs_all.tmp dirs_all.list
    PART=$((PART + 1))
done

rm -f dirs_all.list
PART_COUNT=$((PART - 1))

info "Created $PART_COUNT list parts."

#######################################
# Step 3: Create split directory
#######################################
BASE_NAME="$(basename "$REAL_PATH")"
PARENT_DIR="$(dirname "$REAL_PATH")"
SPLIT_DIR="${PARENT_DIR}/${BASE_NAME}_split"

run_cmd "mkdir -p \"$SPLIT_DIR\""
info "Split directory: $SPLIT_DIR"

#######################################
# Step 4: Process each list
#######################################
for LIST in dirs_part_*.list; do
    FIRST="$(head -n 1 "$LIST")"
    LAST="$(tail -n 1 "$LIST")"
    RANGE_DIR="${FIRST}_bis_${LAST}"
    TARGET_RANGE_DIR="${SPLIT_DIR}/${RANGE_DIR}"

    run_cmd "mkdir -p \"$TARGET_RANGE_DIR\""
    info "Processing range: $RANGE_DIR"

    while IFS= read -r DIR_NAME; do
        SRC="${REAL_PATH}/${DIR_NAME}"
        DST="${TARGET_RANGE_DIR}/${DIR_NAME}"
		run_cmd "mkdir \"$DST\""
		for f in "$SRC"/*; do
            [[ ! -f "$f" ]] && continue
            local link_target="${SRC}/$(basename "$f")"
            local link_name="${DST}/$(basename "$f")"
            
            if [[ "$DRY_RUN" -eq 1 ]]; then
                info "[DRY-RUN] Would create symlink: $link_name -> $link_target"
                if [[ "$VERBOSE" -eq 1 ]]; then
                    echo "[DRY-RUN] Would create symlink: $link_name -> $link_target"
                fi
            else
                if ln -s "$link_target" "$link_name" 2>/dev/null; then
                    info "Created symlink: $link_name -> $link_target"
                    if [[ "$VERBOSE" -eq 1 ]]; then
                        echo "Created symlink: $link_name -> $link_target"
                    fi
                else
                    warn "Failed to create symlink: $link_name -> $link_target"
                fi
            fi
        done
    done < "$LIST"

    run_cmd "rm -f \"$LIST\""
done

#######################################
# Finish
#######################################
info "All directory parts processed successfully."
info "Symbolic link structure ready for Windows clients."
info "Log file: $LOG_FILE"
exit 0
