#!/usr/bin/env bash
###############################################################################
# Script Name: md5_update_paths.sh (Version 1.0)
#
# Description:
#   This script updates MD5 checksum files by changing file paths and names
#   according to instructions in a CSV file, without moving actual files.
#
#   - CSV must have 3 columns:
#       Source_Pfad    Ziel_Pfad    New_filenames
#   - Script operations:
#       1) Read MD5 checksum file
#       2) Update paths from Source_Pfad → Ziel_Pfad
#       3) Rename files according to New_filenames column
#       4) Keep hash values unchanged
#       5) Create backup of original MD5 file
#       6) Save updated MD5 file
#       7) Show colored output and progress
#       8) Create detailed report
#
# Usage:
#   ./md5_update_paths.sh [-n] [-v] [base_path]
#
# Options:
#   -n   Dry-run mode (show changes but don't save)
#   -v   Verbose mode (detailed output)
#
###############################################################################

# --- COLORS for pretty output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# --- SCRIPT VARIABLES ---
DRY_RUN=false
VERBOSE=false
BASE_PATH=""
OUTPUT_FILE="$(basename "$0" .sh)_output_$(date +%Y%m%d_%H%M%S).log"
TERMINAL_LOG=()
LOG_ACTIONS=()
TOTAL_CHANGES=0
PROCESSED_CHANGES=0
MD5_FILE=""
CSV_FILE=""

# --- HELPER FUNCTIONS ---

# Function to capture and display output
output_and_log() {
    local message="$1"
    echo -e "$message"
    # Store plain text version for log (remove color codes)
    local plain_message=$(echo -e "$message" | sed 's/\x1B\[[0-9;]*[JKmsu]//g')
    TERMINAL_LOG+=("$plain_message")
}

# Save action to log with timestamp
log_action() {
    local action="$1"
    local status="${2:-SUCCESS}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    LOG_ACTIONS+=("[$timestamp] [$status] $action")
    TERMINAL_LOG+=("[$timestamp] [$status] $action")
}

# Show error and exit
error_exit() {
    local msg="${RED}ERROR:${NC} $1"
    output_and_log "$msg"
    exit 1
}

# Show warning message
warning() {
    local msg="${YELLOW}WARNING:${NC} $1"
    output_and_log "$msg"
}

# Show success message
success() {
    local msg="${GREEN}SUCCESS:${NC} $1"
    output_and_log "$msg"
}

# Show info message
info() {
    local msg="${BLUE}INFO:${NC} $1"
    output_and_log "$msg"
}

# Show progress bar
show_progress() {
    local current=$1
    local total=$2
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    
    local progress_msg=$(printf "\r${CYAN}Progress: [%*s%*s] %d%% (%d/%d)${NC}" \
        $filled "=" $empty " " $percent $current $total)
    echo -ne "$progress_msg"
}

# Find the next available number in path
get_next_number() {
    local md5_content="$1"
    local prefix="$2"
    local dst_path="$3"
    
    local max_num=0
    
    # Look for existing files with this prefix in the destination path
    while IFS= read -r line; do
        [[ "$line" =~ ^[a-f0-9]{32}[[:space:]]+(.+)$ ]] || continue
        local file_path="${BASH_REMATCH[1]}"
        
        # Check if this file is in our destination path and matches prefix
        if [[ "$file_path" == *"$dst_path"* ]] && [[ "$file_path" == *"${prefix}_nr_"* ]]; then
            # Extract number from filename
            if [[ "$file_path" =~ _([0-9]{4})\.tif$ ]]; then
                local num=${BASH_REMATCH[1]}
                num=$((10#$num))  # Convert from octal to decimal
                if [ "$num" -gt "$max_num" ]; then
                    max_num=$num
                fi
            fi
        fi
    done <<< "$md5_content"
    
    echo $((max_num + 1))
}

# Build new filename based on rename mode
build_new_filename() {
    local old_path="$1"
    local dst_path="$2"
    local newname="$3"
    local md5_content="$4"
    local counter="$5"
    
    local old_filename=$(basename "$old_path")
    
    if [ -n "$newname" ] && [ "$newname" = "rename" ]; then
        # Sequential rename mode - build prefix from path
        IFS='/' read -ra DST_PARTS <<< "$dst_path"
        local L=${#DST_PARTS[@]}
        
        local prefix=""
        local dst_folder=""
        
        if [ $L -ge 2 ]; then
            prefix="${DST_PARTS[$L-2]}_${DST_PARTS[$L-1]}"
            dst_folder="${DST_PARTS[$L-1]}"
        elif [ $L -ge 1 ]; then
            prefix="${DST_PARTS[$L-1]}"
            dst_folder="${DST_PARTS[$L-1]}"
        else
            prefix="file"
            dst_folder="folder"
        fi
        
        # Get starting number for this destination
        if [ "$counter" -eq 1 ]; then
            NEXT_NUM=$(get_next_number "$md5_content" "$prefix" "$dst_path")
        fi
        
        local pad=$(printf "%04d" $((NEXT_NUM + counter - 1)))
        echo "${prefix}_nr_${dst_folder}_${pad}.tif"
        
    elif [ -n "$newname" ] && [ "$newname" != "rename" ]; then
        # Single file rename mode
        echo "${newname}.tif"
        
    else
        # Keep original filename
        echo "$old_filename"
    fi
}

# --- WELCOME MESSAGE ---
output_and_log "${BLUE}=== MD5 Checksum Path Update Script v1.0 ===${NC}"
output_and_log "This tool updates file paths in MD5 checksum files without moving actual files."
output_and_log "Features: Path updates, smart renaming, backup creation"
output_and_log ""

# --- READ COMMAND LINE OPTIONS ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)
            DRY_RUN=true
            info "Dry-run mode active - no changes will be made"
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            info "Verbose mode active - detailed output will be shown"
            shift
            ;;
        -h|--help)
            output_and_log "${BLUE}Usage:${NC} $0 [-n|--dry-run] [-v|--verbose] [base_path]"
            output_and_log "Options:"
            output_and_log "  -n, --dry-run   Show changes without saving"
            output_and_log "  -v, --verbose   Show detailed output"
            output_and_log "  -h, --help      Show this help message"
            exit 0
            ;;
        *)
            BASE_PATH="$1"
            shift
            ;;
    esac
done

# --- GET WORKING DIRECTORY ---
if [ -z "$BASE_PATH" ]; then
    info "No base directory specified."
    echo -ne "Use current directory ($(pwd))? [y/n]: "
    read choice
    TERMINAL_LOG+=("Use current directory ($(pwd))? [y/n]: $choice")
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        BASE_PATH=$(pwd)
    else
        echo -ne "Please enter base directory path: "
        read BASE_PATH
        TERMINAL_LOG+=("Please enter base directory path: $BASE_PATH")
    fi
fi

# --- CHECK IF DIRECTORY EXISTS ---
[ ! -d "$BASE_PATH" ] && error_exit "Base directory '$BASE_PATH' not found."
cd "$BASE_PATH" || error_exit "Cannot change to directory: $BASE_PATH"

info "Working directory: $(pwd)"

# --- FIND MD5 FILES ---
readarray -t MD5_FILES < <(find . -maxdepth 1 -type f \( -name "*.md5" -o -name "*checksum*" -o -name "*hash*" \) | sort)

if [ ${#MD5_FILES[@]} -eq 0 ]; then
    error_exit "No MD5 checksum files found in this directory: $BASE_PATH"
fi

output_and_log "Available MD5 checksum files:"
for i in "${!MD5_FILES[@]}"; do
    output_and_log "$((i+1))) ${MD5_FILES[$i]}"
done

echo -ne "Please select MD5 file (1-${#MD5_FILES[@]}): "
read md5_choice
TERMINAL_LOG+=("Please select MD5 file (1-${#MD5_FILES[@]}): $md5_choice")

if [[ "$md5_choice" =~ ^[0-9]+$ ]] && [ "$md5_choice" -ge 1 ] && [ "$md5_choice" -le ${#MD5_FILES[@]} ]; then
    MD5_FILE="${MD5_FILES[$((md5_choice-1))]}"
    info "Selected MD5 file: $MD5_FILE"
else
    error_exit "Invalid selection: $md5_choice"
fi

# --- FIND CSV FILES ---
readarray -t CSV_FILES < <(find . -maxdepth 1 -type f \( -name "*.csv" -o -name "*.list" -o -name "*.txt" \) | sort)

if [ ${#CSV_FILES[@]} -eq 0 ]; then
    error_exit "No CSV instruction files found in this directory: $BASE_PATH"
fi

output_and_log "Available CSV instruction files:"
for i in "${!CSV_FILES[@]}"; do
    output_and_log "$((i+1))) ${CSV_FILES[$i]}"
done

echo -ne "Please select CSV file (1-${#CSV_FILES[@]}): "
read csv_choice
TERMINAL_LOG+=("Please select CSV file (1-${#CSV_FILES[@]}): $csv_choice")

if [[ "$csv_choice" =~ ^[0-9]+$ ]] && [ "$csv_choice" -ge 1 ] && [ "$csv_choice" -le ${#CSV_FILES[@]} ]; then
    CSV_FILE="${CSV_FILES[$((csv_choice-1))]}"
    info "Selected CSV file: $CSV_FILE"
else
    error_exit "Invalid selection: $csv_choice"
fi

# --- CHECK FILES ---
[ ! -r "$MD5_FILE" ] && error_exit "Cannot read MD5 file: $MD5_FILE"
[ ! -r "$CSV_FILE" ] && error_exit "Cannot read CSV file: $CSV_FILE"

# --- READ MD5 FILE CONTENT ---
MD5_CONTENT=$(cat "$MD5_FILE")
info "MD5 file loaded with $(echo "$MD5_CONTENT" | wc -l) entries"

# --- COUNT CSV ROWS ---
TOTAL_ROWS=$(($(wc -l < "$CSV_FILE") - 1))
info "Number of CSV instructions to process: $TOTAL_ROWS"

# --- CREATE BACKUP ---
BACKUP_FILE="${MD5_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
if [ "$DRY_RUN" = false ]; then
    cp "$MD5_FILE" "$BACKUP_FILE"
    success "Backup created: $BACKUP_FILE"
fi

# --- PROCESS UPDATES ---
output_and_log "$(echo "=" | tr '=' '-' | head -c 60)"
info "Starting MD5 file updates..."

UPDATED_MD5_CONTENT="$MD5_CONTENT"
NEXT_NUM=1

{
    # Skip CSV header
    read
    while IFS= read -r LINE; do
        # Remove Windows CRLF characters
        LINE=$(echo "$LINE" | tr -d '\r')
        
        # Skip empty lines
        [ -z "$LINE" ] && continue
        
        # Parse CSV - supports comma, semicolon, tab
        IFS=$',;\t' read -r SRC DST NEWNAME <<< "$LINE"
        
        # Clean up values
        SRC=$(echo "$SRC" | xargs)
        DST=$(echo "$DST" | xargs)
        NEWNAME=$(echo "$NEWNAME" | xargs)
        
        [ -z "$SRC" ] && continue
        
        PROCESSED_CHANGES=$((PROCESSED_CHANGES + 1))
        show_progress $PROCESSED_CHANGES $TOTAL_ROWS
        
        output_and_log ""
        info "Processing [$PROCESSED_CHANGES/$TOTAL_ROWS]: $SRC → $DST"
        
        # Find and update matching entries in MD5 file
        local file_counter=1
        local temp_content=""
        
        while IFS= read -r md5_line; do
            if [[ "$md5_line" =~ ^([a-f0-9]{32})[[:space:]]+(.+)$ ]]; then
                local hash="${BASH_REMATCH[1]}"
                local file_path="${BASH_REMATCH[2]}"
                
                # Check if this file path starts with our source path
                if [[ "$file_path" == "$SRC"* ]]; then
                    # Build new filename
                    local new_filename=$(build_new_filename "$file_path" "$DST" "$NEWNAME" "$UPDATED_MD5_CONTENT" "$file_counter")
                    
                    # Replace source path with destination path and new filename
                    local new_path="${DST}/${new_filename}"
                    
                    # Create new MD5 line
                    local new_line="$hash  $new_path"
                    
                    if [ "$VERBOSE" = true ]; then
                        info "  Update: $(basename "$file_path") → $(basename "$new_path")"
                    fi
                    
                    log_action "Updated MD5 entry: $file_path → $new_path"
                    temp_content+="$new_line"$'\n'
                    file_counter=$((file_counter + 1))
                    TOTAL_CHANGES=$((TOTAL_CHANGES + 1))
                else
                    # Keep original line
                    temp_content+="$md5_line"$'\n'
                fi
            else
                # Keep non-MD5 lines (comments, etc.)
                temp_content+="$md5_line"$'\n'
            fi
        done <<< "$UPDATED_MD5_CONTENT"
        
        UPDATED_MD5_CONTENT="$temp_content"
        
        if [ "$file_counter" -gt 1 ]; then
            success "Updated $((file_counter - 1)) entries for path: $SRC"
        else
            warning "No matching entries found for path: $SRC"
        fi
        
    done
} < "$CSV_FILE"

output_and_log ""
show_progress $TOTAL_ROWS $TOTAL_ROWS
output_and_log ""
output_and_log ""

# --- SAVE UPDATED MD5 FILE ---
if [ "$TOTAL_CHANGES" -gt 0 ]; then
    if [ "$DRY_RUN" = true ]; then
        info "Dry-run mode: Would update $TOTAL_CHANGES entries in MD5 file"
        
        # Show preview of changes
        output_and_log "${YELLOW}Preview of updated MD5 file:${NC}"
        echo "$UPDATED_MD5_CONTENT" | head -10
        if [ "$(echo "$UPDATED_MD5_CONTENT" | wc -l)" -gt 10 ]; then
            info "... (showing first 10 lines)"
        fi
    else
        echo "$UPDATED_MD5_CONTENT" > "$MD5_FILE"
        success "Updated MD5 file saved: $MD5_FILE"
        success "Total entries updated: $TOTAL_CHANGES"
        log_action "MD5 file updated with $TOTAL_CHANGES changes"
    fi
else
    warning "No matching entries found - MD5 file unchanged"
fi

# --- SAVE DETAILED REPORT ---
{
    echo "=== MD5 Checksum Path Update Report ==="
    echo "Execution time: $(date)"
    echo "Base directory: $BASE_PATH"
    echo "MD5 file: $MD5_FILE"
    echo "CSV instruction file: $CSV_FILE"
    echo "Dry-run mode: $DRY_RUN"
    echo "Verbose mode: $VERBOSE"
    echo "Total CSV rows processed: $PROCESSED_CHANGES"
    echo "Total MD5 entries updated: $TOTAL_CHANGES"
    echo
    if [ "$DRY_RUN" = true ]; then
        echo "=== DRY-RUN MODE - NO ACTUAL CHANGES WERE MADE ==="
        echo "The following shows what would happen in real execution:"
        echo
    fi
    echo "=== Complete Terminal Output ==="
    printf "%s\n" "${TERMINAL_LOG[@]}"
    echo
    echo "=== Operation Summary ==="
    printf "%s\n" "${LOG_ACTIONS[@]}"
} > "$OUTPUT_FILE"

success "Detailed report saved: $OUTPUT_FILE"
if [ "$DRY_RUN" = false ] && [ "$TOTAL_CHANGES" -gt 0 ]; then
    success "Backup of original MD5 file: $BACKUP_FILE"
fi
success "All operations completed!"

if [ "$DRY_RUN" = true ]; then
    info "This was a dry-run. Remove -n parameter to make actual changes."
fi