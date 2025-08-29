#!/usr/bin/env bash
###############################################################################
# Script Name: safe_multi_delete_with_csv.sh (v.5.0)
# Author: Mustafa Demiroglu
#
# Description:
#   This script safely deletes files based on a CSV/TXT/List file.
#   It is designed for cross-platform use (Linux, macOS, WSL on Windows)
#   and compatible with most bash versions.
#
# Features:
#   - Reads CSV/TXT/List file containing paths and "To-Do" instructions.
#   - Detects column separator automatically (comma, semicolon, tab, space).
#   - If "delete" is specified in To-Do column, the file will be deleted.
#   - Normalizes paths (absolute/relative, ./, Windows ↔ Linux).
#   - Dry-run mode (-n): only shows what would be deleted.
#   - Parallel mode (-p): executes deletions in parallel if supported.
#   - Verbose mode (-v): prints extra info.
#   - Interactive confirmation before actual deletion.
#   - If no path argument is given, script asks to use current working directory.
#   - If no CSV file is given, script lists available *.csv / *.txt / *.list
#     files in current folder and asks the user to choose.
#   - Always writes logs: 
#       * delete_log_YYYYMMDD_HHMMSS.txt
#       * delete_errors_YYYYMMDD_HHMMSS.txt
#
# Usage Examples:
#   ./safe_delete_from_csv.sh --file mylist.csv --dry-run
#   ./safe_delete_from_csv.sh -f files_to_delete.txt -v -p
#
# Options:
#   -f, --file <path>     : CSV/TXT/List file to process
#   -n, --dry-run         : Dry run mode (no deletions, just print actions)
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
SEP=$'\t'   # default, will auto-detect
LOGFILE="delete_log_$(date +%Y%m%d_%H%M%S).txt"
ERRFILE="delete_errors_$(date +%Y%m%d_%H%M%S).txt"

# --- Functions ---------------------------------------------------------------

print_help() {
    sed -n '2,40p' "$0"
}

log() {
    echo "$*" | tee -a "$LOGFILE"
}

log_info() {
    if $VERBOSE; then
        echo "[INFO] $*" | tee -a "$LOGFILE"
    else
        echo "$*" >>"$LOGFILE"
    fi
}

normalize_path() {
    local p="$1"
    # Replace Windows backslashes with Linux slashes
    p="${p//\\//}"
    # Remove leading ./ if present
    p="${p#./}"
    # Remove duplicate slashes
    p="${p//\/\//\/}"
    # Try to resolve relative path to absolute
    if [[ "$p" != /* ]]; then
        p="$(pwd)/$p"
    fi
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

detect_separator() {
    local header
    header="$(head -n1 "$FILE")"
    case "$header" in
        *";"*) SEP=";" ;;
        *","*) SEP="," ;;
        *"	"*) SEP=$'\t' ;; # real tab
        *" "*) SEP=" " ;;
        *) SEP=$'\t' ;;
    esac
}

delete_file() {
    local f="$1"
    if $DRYRUN; then
        log "[DRY-RUN] Would delete: $f"
        return
    fi
    if [[ -f "$f" ]]; then
        if rm -f -- "$f"; then
            log "[DELETED] $f"
        else
            echo "[ERROR] Could not delete: $f" | tee -a "$ERRFILE"
        fi
    else
        echo "[SKIP] File not found: $f" | tee -a "$ERRFILE"
    fi
}

process_file() {
    tail -n +2 "$FILE" | while IFS="$SEP" read -r f todo || [[ -n "$f" ]]; do
        [[ -z "$f" ]] && continue
        f="$(normalize_path "$f")"
        if [[ "$todo" == "delete" ]]; then
            delete_file "$f"
        else
            log_info "Skip: $f"
        fi
    done
}

# --- Parse args --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file) FILE="$2"; shift 2 ;;
        -n|--dry-run) DRYRUN=true; shift ;;
        -p|--parallel) PARALLEL=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help) print_help; exit 0 ;;
        *) echo "Unknown option: $1"; print_help; exit 1 ;;
    esac
done

# --- Main --------------------------------------------------------------------
choose_file_if_missing
detect_separator

echo "Using file: $FILE"
echo "Log file: $LOGFILE"
echo "Error file: $ERRFILE"

if $DRYRUN; then
    echo "==== DRY RUN MODE ====" | tee -a "$LOGFILE"
    echo "No files will be deleted. These are the planned actions:" | tee -a "$LOGFILE"
else
    if ! ask_confirmation "Proceed with deletion from $FILE?"; then
        echo "Aborted by user."
        exit 1
    fi
fi

if $PARALLEL; then
    log_info "Running in parallel mode"
    tail -n +2 "$FILE" | awk -F"$SEP" '$2=="delete"{print $1}' | while read -r f; do
        f="$(normalize_path "$f")"
        echo "$f"
    done | xargs -I{} -P"$(nproc 2>/dev/null || echo 4)" bash -c '
        f="{}"
        if [[ "'"$DRYRUN"'" == "true" ]]; then
            echo "[DRY-RUN] Would delete: $f" >>"'"$LOGFILE"'"
        else
            if [[ -f "$f" ]]; then
                if rm -f -- "$f"; then
                    echo "[DELETED] $f" >>"'"$LOGFILE"'"
                else
                    echo "[ERROR] Could not delete: $f" >>"'"$ERRFILE"'"
                fi
            else
                echo "[SKIP] File not found: $f" >>"'"$ERRFILE"'"
            fi
        fi
    '
else
    process_file
fi

echo "Done. Logs written to $LOGFILE, errors to $ERRFILE."
