#!/usr/bin/env bash
###############################################################################
# Script Name: safe_multi_delete_with_csv.sh (v.1.2)
# Author: Mustafa Demiroglu
#
# Description:
#   This script safely deletes files based on a CSV/TXT/List file.
#   It is designed for cross-platform use (Linux, macOS, WSL on Windows)
#   and compatible with most bash versions.
#
# Features:
#   - Reads CSV/TXT/List file containing paths and "To-Do" instructions.
#   - If "delete" is specified in To-Do column, the file will be deleted.
#   - Normalizes paths (leading slashes, relative/absolute).
#   - Dry-run mode: only shows what would be deleted.
#   - Parallel mode: executes deletions in parallel if supported.
#   - Verbose mode: prints extra info.
#   - Interactive confirmation before actual deletion.
#   - If no path argument is given, script asks to use current working directory.
#   - If no CSV file is given, script lists available *.csv / *.txt / *.list
#     files in current folder and asks the user to choose.
#
# Usage Examples:
#   ./safe_delete_from_csv.sh --file mylist.csv --dry-run
#   ./safe_delete_from_csv.sh -f files_to_delete.txt -v -p
#
# Options:
#   -f, --file <path>     : CSV/TXT/List file to process
#   -d, --dry-run         : Dry run mode (no deletions, just print actions)
#   -p, --parallel        : Run deletions in parallel (if supported)
#   -v, --verbose         : Verbose output
#   -h, --help            : Show this help
###############################################################################

set -euo pipefail

# Default options
DRYRUN=false
VERBOSE=false
PARALLEL=false
FILE=""

# --- Functions ---------------------------------------------------------------

print_help() {
    sed -n '2,40p' "$0"
}

log() {
    if $VERBOSE; then
        echo "[INFO] $*"
    fi
}

normalize_path() {
    local p="$1"
    # Remove leading ./ if present
    p="${p#./}"
    # Ensure no double slashes
    p="${p//\/\//\/}"
    echo "$p"
}

ask_confirmation() {
    local prompt="$1"
    read -rp "$prompt [y/N]: " ans
    case "$ans" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

choose_file_if_missing() {
    if [[ -z "$FILE" ]]; then
        echo "No CSV/TXT/List file provided."
        echo "Searching for candidate files in current directory..."
        local choices=( *.csv *.CSV *.txt *.TXT *.list *.LIST )
        local filtered=()
        for f in "${choices[@]}"; do
            [[ -f "$f" ]] && filtered+=("$f")
        done
        if [[ "${#filtered[@]}" -eq 0 ]]; then
            echo "No candidate file found. Exiting."
            exit 1
        fi
        echo "Select file to process:"
        select f in "${filtered[@]}"; do
            FILE="$f"
            break
        done
    fi
}

delete_file() {
    local f="$1"
    if $DRYRUN; then
        echo "[DRY-RUN] Would delete: $f"
        return
    fi
    if [[ -f "$f" ]]; then
        rm -f -- "$f"
        echo "[DELETED] $f"
    else
        echo "[SKIP] File not found: $f"
    fi
}

process_file() {
    local line f todo
    while IFS=$'\t' read -r f todo || [[ -n "$f" ]]; do
        f="$(normalize_path "$f")"
        if [[ "$todo" == "delete" ]]; then
            delete_file "$f"
        else
            log "Skip: $f"
        fi
    done < "$FILE"
}

# --- Parse args --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file) FILE="$2"; shift 2 ;;
        -d|--dry-run) DRYRUN=true; shift ;;
        -p|--parallel) PARALLEL=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help) print_help; exit 0 ;;
        *) echo "Unknown option: $1"; print_help; exit 1 ;;
    esac
done

# --- Main --------------------------------------------------------------------
choose_file_if_missing

echo "Using file: $FILE"

if ! $DRYRUN; then
    if ! ask_confirmation "Proceed with deletion from $FILE?"; then
        echo "Aborted by user."
        exit 1
    fi
fi

if $PARALLEL; then
    log "Running in parallel mode"
    grep -P '\tdelete$' "$FILE" | cut -f1 | while read -r f; do
        f="$(normalize_path "$f")"
        if $DRYRUN; then
            echo "[DRY-RUN] Would delete: $f"
        else
            echo "$f"
        fi
    done | xargs -I{} -P"$(nproc 2>/dev/null || echo 4)" bash -c '[[ -f "$1" ]] && rm -f -- "$1" && echo "[DELETED] $1" || echo "[SKIP] File not found: $1"' -- {}
else
    process_file
fi

echo "Done."
