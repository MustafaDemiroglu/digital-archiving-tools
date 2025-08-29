#!/usr/bin/env bash
###############################################################################
# Script Name: safe_multi_delete_with_csv.sh (v.2.2)
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
#   - Creates log files for operations and errors.
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CURRENT_DIR="$(pwd)"

# Log files
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="${CURRENT_DIR}/delete_log_${TIMESTAMP}.log"
ERROR_FILE="${CURRENT_DIR}/delete_errors_${TIMESTAMP}.log"

# --- Functions ---------------------------------------------------------------

print_help() {
    sed -n '2,45p' "$0"
}

log() {
    local msg="$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$LOG_FILE"
    if $VERBOSE; then
        echo "[INFO] $msg"
    fi
}

error_log() {
    local msg="$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $msg" >> "$ERROR_FILE"
    echo "[ERROR] $msg"
}

normalize_path() {
    local p="$1"
    local normalized_path
    
    # Remove leading ./
    p="${p#./}"
    
    # Handle relative paths - make them absolute based on current directory
    if [[ "$p" != /* ]]; then
        p="${CURRENT_DIR}/${p}"
    fi
    
    # Use realpath if available, otherwise manual normalization
    if command -v realpath >/dev/null 2>&1; then
        normalized_path=$(realpath -m "$p" 2>/dev/null || echo "$p")
    else
        # Manual path normalization
        normalized_path="$p"
        # Remove double slashes
        normalized_path="${normalized_path//\/\//\/}"
        # Remove trailing slash unless it's root
        if [[ "$normalized_path" != "/" ]]; then
            normalized_path="${normalized_path%/}"
        fi
    fi
    
    echo "$normalized_path"
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
        log "DRY-RUN: Would delete $f"
        return 0
    fi
    
    if [[ -f "$f" ]]; then
        if rm -f -- "$f" 2>/dev/null; then
            echo "[DELETED] $f"
            log "Successfully deleted: $f"
            return 0
        else
            error_log "Failed to delete: $f"
            echo "[FAILED] Could not delete: $f"
            return 1
        fi
    else
        echo "[SKIP] File not found: $f"
        log "File not found (skipped): $f"
        return 1
    fi
}

parse_csv_line() {
    local line="$1"
    local separator="$2"
    local f todo
    
    if [[ "$separator" == "tab" ]]; then
        f=$(echo "$line" | cut -d

process_file_parallel() {
    local temp_file=$(mktemp)
    local files_to_delete=0
    local separator
    
    # Detect separator
    separator=$(detect_separator "$FILE")
    log "Detected separator for parallel processing: $separator"
    echo "Detected CSV separator: $separator"
    
    # Extract files marked for deletion
    local line_num=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        [[ -z "$line" ]] && continue
        
        # Parse CSV line
        local parsed_result f todo
        parsed_result=$(parse_csv_line "$line" "$separator")
        f=$(echo "$parsed_result" | cut -d'|' -f1)
        todo=$(echo "$parsed_result" | cut -d'|' -f2)
        
        # Skip header
        if [[ "$f" == *"Dateipfad"* ]] || [[ "$f" == *"Path"* ]] || [[ "$f" == *"File"* ]] || [[ "$line_num" -eq 1 ]]; then
            continue
        fi
        
        # Skip if no filename
        if [[ -z "$f" ]]; then
            continue
        fi
        
        if [[ "${todo,,}" == "delete" ]]; then
            normalized_path=$(normalize_path "$f")
            echo "$normalized_path" >> "$temp_file"
            ((files_to_delete++))
        fi
    done < "$FILE"
    
    if [[ $files_to_delete -eq 0 ]]; then
        echo "No files marked for deletion found."
        rm -f "$temp_file"
        return 0
    fi
    
    echo "Processing $files_to_delete files in parallel..."
    log "Starting parallel processing of $files_to_delete files"
    
    # Process files in parallel
    export -f delete_file log error_log
    export DRYRUN VERBOSE LOG_FILE ERROR_FILE
    
    cat "$temp_file" | xargs -I {} -P "$(nproc 2>/dev/null || echo 4)" bash -c 'delete_file "$1"' -- {}
    
    rm -f "$temp_file"
    log "Parallel processing completed"
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

echo "Using file: $FILE"

# Initialize log files
if $DRYRUN; then
    echo "# DRY RUN MODE" > "$LOG_FILE"
    echo "# This is a dry run. No actual changes will be made." >> "$LOG_FILE"
    echo "# Run without -n/--dry-run to see actual results." >> "$LOG_FILE"
    echo "# =================================================" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
else
    echo "# File Deletion Log" > "$LOG_FILE"
    echo "# Generated on: $(date)" >> "$LOG_FILE"
    echo "# =================================================" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
fi

log "Script started with file: $FILE"
log "Current working directory: $CURRENT_DIR"
log "Dry run mode: $DRYRUN"
log "Verbose mode: $VERBOSE"
log "Parallel mode: $PARALLEL"

# Debug: Show first few lines of CSV file
echo "Analyzing CSV file structure..."
log "First 3 lines of CSV file:"
head -n 3 "$FILE" | while IFS= read -r line; do
    log "CSV Line: '$line'"
done

# Confirm deletion if not dry run
if ! $DRYRUN; then
    if ! ask_confirmation "Proceed with deletion from $FILE?"; then
        echo "Aborted by user."
        log "Operation aborted by user"
        exit 1
    fi
fi

# Process files
if $PARALLEL; then
    log "Running in parallel mode"
    process_file_parallel
else
    log "Running in sequential mode"
    process_file_sequential
fi

echo "Done."
echo "Log file: $LOG_FILE"
if [[ -f "$ERROR_FILE" ]] && [[ -s "$ERROR_FILE" ]]; then
    echo "Error file: $ERROR_FILE"
fi

log "Script completed successfully"\t' -f1)
        todo=$(echo "$line" | cut -d

process_file_parallel() {
    local temp_file=$(mktemp)
    local files_to_delete=0
    
    # Extract files marked for deletion
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        
        local f todo
        if [[ "$line" == *";"* ]]; then
            f=$(echo "$line" | cut -d';' -f1)
            todo=$(echo "$line" | cut -d';' -f2)
        elif [[ "$line" == *","* ]]; then
            f=$(echo "$line" | cut -d',' -f1)
            todo=$(echo "$line" | cut -d',' -f2)
        else
            continue
        fi
        
        # Skip header
        if [[ "$f" == *"Dateipfad"* ]] || [[ "$f" == *"Path"* ]] || [[ "$f" == *"File"* ]]; then
            continue
        fi
        
        if [[ "${todo,,}" == "delete" ]]; then
            normalized_path=$(normalize_path "$f")
            echo "$normalized_path" >> "$temp_file"
            ((files_to_delete++))
        fi
    done < "$FILE"
    
    if [[ $files_to_delete -eq 0 ]]; then
        echo "No files marked for deletion found."
        rm -f "$temp_file"
        return 0
    fi
    
    echo "Processing $files_to_delete files in parallel..."
    log "Starting parallel processing of $files_to_delete files"
    
    # Process files in parallel
    export -f delete_file log error_log
    export DRYRUN VERBOSE LOG_FILE ERROR_FILE
    
    cat "$temp_file" | xargs -I {} -P "$(nproc 2>/dev/null || echo 4)" bash -c 'delete_file "$1"' -- {}
    
    rm -f "$temp_file"
    log "Parallel processing completed"
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

echo "Using file: $FILE"

# Initialize log files
if $DRYRUN; then
    echo "# DRY RUN MODE" > "$LOG_FILE"
    echo "# This is a dry run. No actual changes will be made." >> "$LOG_FILE"
    echo "# Run without -n/--dry-run to see actual results." >> "$LOG_FILE"
    echo "# =================================================" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
else
    echo "# File Deletion Log" > "$LOG_FILE"
    echo "# Generated on: $(date)" >> "$LOG_FILE"
    echo "# =================================================" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
fi

log "Script started with file: $FILE"
log "Current working directory: $CURRENT_DIR"
log "Dry run mode: $DRYRUN"
log "Verbose mode: $VERBOSE"
log "Parallel mode: $PARALLEL"

# Confirm deletion if not dry run
if ! $DRYRUN; then
    if ! ask_confirmation "Proceed with deletion from $FILE?"; then
        echo "Aborted by user."
        log "Operation aborted by user"
        exit 1
    fi
fi

# Process files
if $PARALLEL; then
    log "Running in parallel mode"
    process_file_parallel
else
    log "Running in sequential mode"
    process_file_sequential
fi

echo "Done."
echo "Log file: $LOG_FILE"
if [[ -f "$ERROR_FILE" ]] && [[ -s "$ERROR_FILE" ]]; then
    echo "Error file: $ERROR_FILE"
fi

log "Script completed successfully"\t' -f2)
    else
        f=$(echo "$line" | cut -d"$separator" -f1)
        todo=$(echo "$line" | cut -d"$separator" -f2)
    fi
    
    # Clean up whitespace and quotes
    f=$(echo "$f" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/^"//;s/"$//')
    todo=$(echo "$todo" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/^"//;s/"$//')
    
    echo "$f|$todo"
}

process_file_sequential() {
    local line f todo normalized_path
    local line_num=0
    local files_processed=0
    local files_deleted=0
    local files_failed=0
    local separator
    
    # Detect separator
    separator=$(detect_separator "$FILE")
    log "Detected separator: $separator"
    echo "Detected CSV separator: $separator"
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        ((line_num++))
        
        # Skip empty lines
        [[ -z "$line" ]] && continue
        
        # Parse CSV line
        local parsed_result
        parsed_result=$(parse_csv_line "$line" "$separator")
        f=$(echo "$parsed_result" | cut -d'|' -f1)
        todo=$(echo "$parsed_result" | cut -d'|' -f2)
        
        # Debug output for first few lines
        if [[ $line_num -le 5 ]]; then
            log "Line $line_num: '$line' -> File: '$f', Todo: '$todo'"
        fi
        
        # Skip header line
        if [[ "$f" == *"Dateipfad"* ]] || [[ "$f" == *"Path"* ]] || [[ "$f" == *"File"* ]] || [[ "$line_num" -eq 1 ]]; then
            log "Skipping header line: $line"
            continue
        fi
        
        # Skip if no filename
        if [[ -z "$f" ]]; then
            log "Skipping empty filename at line $line_num"
            continue
        fi
        
        # Normalize path
        normalized_path=$(normalize_path "$f")
        ((files_processed++))
        
        # Check if we should delete
        if [[ "${todo,,}" == "delete" ]]; then
            log "Processing file for deletion: $normalized_path"
            if delete_file "$normalized_path"; then
                ((files_deleted++))
            else
                ((files_failed++))
            fi
        else
            log "Skipping (not marked for deletion): $normalized_path (todo: '$todo')"
        fi
    done < "$FILE"
    
    echo "Processed: $files_processed files"
    echo "Deleted: $files_deleted files"
    if [[ $files_failed -gt 0 ]]; then
        echo "Failed: $files_failed files (see $ERROR_FILE)"
    fi
    
    log "Summary - Processed: $files_processed, Deleted: $files_deleted, Failed: $files_failed"
}

process_file_parallel() {
    local temp_file=$(mktemp)
    local files_to_delete=0
    
    # Extract files marked for deletion
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        
        local f todo
        if [[ "$line" == *";"* ]]; then
            f=$(echo "$line" | cut -d';' -f1)
            todo=$(echo "$line" | cut -d';' -f2)
        elif [[ "$line" == *","* ]]; then
            f=$(echo "$line" | cut -d',' -f1)
            todo=$(echo "$line" | cut -d',' -f2)
        else
            continue
        fi
        
        # Skip header
        if [[ "$f" == *"Dateipfad"* ]] || [[ "$f" == *"Path"* ]] || [[ "$f" == *"File"* ]]; then
            continue
        fi
        
        if [[ "${todo,,}" == "delete" ]]; then
            normalized_path=$(normalize_path "$f")
            echo "$normalized_path" >> "$temp_file"
            ((files_to_delete++))
        fi
    done < "$FILE"
    
    if [[ $files_to_delete -eq 0 ]]; then
        echo "No files marked for deletion found."
        rm -f "$temp_file"
        return 0
    fi
    
    echo "Processing $files_to_delete files in parallel..."
    log "Starting parallel processing of $files_to_delete files"
    
    # Process files in parallel
    export -f delete_file log error_log
    export DRYRUN VERBOSE LOG_FILE ERROR_FILE
    
    cat "$temp_file" | xargs -I {} -P "$(nproc 2>/dev/null || echo 4)" bash -c 'delete_file "$1"' -- {}
    
    rm -f "$temp_file"
    log "Parallel processing completed"
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

echo "Using file: $FILE"

# Initialize log files
if $DRYRUN; then
    echo "# DRY RUN MODE" > "$LOG_FILE"
    echo "# This is a dry run. No actual changes will be made." >> "$LOG_FILE"
    echo "# Run without -n/--dry-run to see actual results." >> "$LOG_FILE"
    echo "# =================================================" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
else
    echo "# File Deletion Log" > "$LOG_FILE"
    echo "# Generated on: $(date)" >> "$LOG_FILE"
    echo "# =================================================" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
fi

log "Script started with file: $FILE"
log "Current working directory: $CURRENT_DIR"
log "Dry run mode: $DRYRUN"
log "Verbose mode: $VERBOSE"
log "Parallel mode: $PARALLEL"

# Confirm deletion if not dry run
if ! $DRYRUN; then
    if ! ask_confirmation "Proceed with deletion from $FILE?"; then
        echo "Aborted by user."
        log "Operation aborted by user"
        exit 1
    fi
fi

# Process files
if $PARALLEL; then
    log "Running in parallel mode"
    process_file_parallel
else
    log "Running in sequential mode"
    process_file_sequential
fi

echo "Done."
echo "Log file: $LOG_FILE"
if [[ -f "$ERROR_FILE" ]] && [[ -s "$ERROR_FILE" ]]; then
    echo "Error file: $ERROR_FILE"
fi

log "Script completed successfully"