#!/usr/bin/env bash
###############################################################################
# Script Name: safe_multi_delete_with_csv.sh (v.3.3)
# Author: Mustafa Demiroglu
#
# Description:
#   Simple script to delete files based on CSV/TXT/List file.
#   Reads file paths from first column and action from second column.
#   If second column contains "delete", the file will be deleted.
#
# Usage Examples:
#   ./safe_multi_delete_with_csv.sh -f mylist.csv -n
#   ./safe_multi_delete_with_csv.sh -f files_to_delete.txt -v
#
# Options:
#   -f, --file <path>     : CSV/TXT/List file to process
#   -n, --dry-run         : Dry run mode (no deletions, just show what would be deleted)
#   -v, --verbose         : Verbose output
#   -h, --help            : Show this help
###############################################################################

set -euo pipefail

# Default options
DRYRUN=false
VERBOSE=false
FILE=""

# Log files
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="./delete_log_${TIMESTAMP}.log"
ERROR_FILE="./delete_errors_${TIMESTAMP}.log"

print_help() {
    sed -n '2,20p' "$0"
}

log_msg() {
    echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"
    if $VERBOSE; then
        echo "[INFO] $*"
    fi
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file) FILE="$2"; shift 2 ;;
        -n|--dry-run) DRYRUN=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help) print_help; exit 0 ;;
        *) echo "Unknown option: $1"; print_help; exit 1 ;;
    esac
done

# Check if file is provided
if [[ -z "$FILE" ]]; then
    echo "Error: No file provided. Use -f option."
    exit 1
fi

if [[ ! -f "$FILE" ]]; then
    echo "Error: File $FILE not found."
    exit 1
fi

echo "Using file: $FILE"

# Initialize log
if $DRYRUN; then
    echo "# DRY RUN MODE - No files will actually be deleted" > "$LOG_FILE"
else
    echo "# File Deletion Log - $(date)" > "$LOG_FILE"
fi

log_msg "Starting script with file: $FILE"
log_msg "Dry run: $DRYRUN, Verbose: $VERBOSE"

# Show first few lines for debugging
echo "First 3 lines of file:"
head -n 3 "$FILE"

# Ask for confirmation if not dry run
if ! $DRYRUN; then
    echo "[INFO] Asking for user confirmation to proceed with deletion..."
    read -p "Proceed with deletion? [y/N]: " answer
    if [[ -z "$answer" ]]; then
        echo "[INFO] No input received, using default 'n'."
        answer="n"
    fi
    case "$answer" in
        [yY]|[yY][eE][sS]) 
            echo "[INFO] Proceeding with deletion."
            ;;
        *) 
            echo "[INFO] Deletion aborted."
            exit 0
            ;;
    esac
fi

# Process file
line_count=0
deleted_count=0
failed_count=0

echo "Processing file..."
log_msg "Starting to process file line by line"

while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_count++))
    
    # Debug: show what we're processing
    if $VERBOSE; then
        echo "Processing line $line_count: $line"
    fi
    
    # Skip empty lines
    if [[ -z "$line" ]]; then
        log_msg "Skipping empty line $line_count"
        continue
    fi
    
    # Try different separators: tab, semicolon, comma
    filepath=""
    action=""
    
    # Check for tab, semicolon, or comma separation
    if [[ "$line" == *$'\t'* ]]; then
        filepath=$(echo "$line" | cut -d$'\t' -f1)
        action=$(echo "$line" | cut -d$'\t' -f2)
    elif [[ "$line" == *";"* ]]; then
        filepath=$(echo "$line" | cut -d';' -f1)
        action=$(echo "$line" | cut -d';' -f2)
    elif [[ "$line" == *","* ]]; then
        filepath=$(echo "$line" | cut -d',' -f1)
        action=$(echo "$line" | cut -d',' -f2)
    else
        log_msg "Skipping line $line_count: no separator found (line content: '$line')"
        continue
    fi
    
    # Clean whitespace and quotes
    filepath=$(echo "$filepath" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/^"//;s/"$//')
    action=$(echo "$action" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/^"//;s/"$//')
    
    if $VERBOSE; then
        echo "  -> Filepath: '$filepath', Action: '$action'"
    fi
    
    # Skip header lines
    if [[ "$filepath" == *"Dateipfad"* ]] || [[ "$filepath" == *"Path"* ]] || [[ "$line_count" -eq 1 ]]; then
        log_msg "Skipping header line $line_count"
        if $VERBOSE; then
            echo "  -> Skipping header line"
        fi
        continue
    fi
    
    # Skip if no filepath
    if [[ -z "$filepath" ]]; then
        log_msg "Skipping line $line_count: empty filepath"
        continue
    fi
    
    # Make absolute path if relative
    if [[ "$filepath" != /* ]]; then
        filepath="$(pwd)/$filepath"
    fi
    
    # Check if action is delete
    if [[ "${action,,}" == "delete" ]]; then
        if $VERBOSE; then
            echo "  -> File marked for deletion: $filepath"
        fi
        if $DRYRUN; then
            echo "[DRY-RUN] Would delete: $filepath"
            log_msg "DRY-RUN: Would delete $filepath"
            ((deleted_count++))
        else
            if [[ -f "$filepath" ]]; then
                if rm -f "$filepath" 2>/dev/null; then
                    echo "[DELETED] $filepath"
                    log_msg "Successfully deleted: $filepath"
                    ((deleted_count++))
                else
                    echo "[FAILED] Could not delete: $filepath"
                    echo "[$(date '+%H:%M:%S')] Failed to delete: $filepath" >> "$ERROR_FILE"
                    ((failed_count++))
                fi
            else
                echo "[NOT FOUND] $filepath"
                log_msg "File not found: $filepath"
            fi
        fi
    else
        if $VERBOSE; then
            echo "  -> Skipping (not marked for deletion): $filepath"
        fi
        log_msg "Skipping (not marked for deletion): $filepath"
    fi
    
done < "$FILE"

echo ""
echo "Summary:"
echo "- Lines processed: $line_count"
if ! $DRYRUN; then
    echo "- Files deleted: $deleted_count"
    if [[ $failed_count -gt 0 ]]; then
        echo "- Failed deletions: $failed_count (see $ERROR_FILE)"
    fi
fi
echo "- Log file: $LOG_FILE"

log_msg "Script completed. Processed: $line_count, Deleted: $deleted_count, Failed: $failed_count"
