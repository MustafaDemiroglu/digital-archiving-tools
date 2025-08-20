#!/usr/bin/env bash
###############################################################################
# Script Name: md5_update_paths.sh (Version 2.8)
###############################################################################

# --- COLORS for pretty output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# --- SCRIPT VARIABLES ---
DRY_RUN=false
VERBOSE=false
BASE_PATH=""
SEARCH_SUBDIRS=false
OUTPUT_FILE=""
TERMINAL_LOG=()
LOG_ACTIONS=()
TOTAL_CHANGES=0
PROCESSED_CHANGES=0
MD5_FILE=""
CSV_FILE=""
CSV_PROCESSING_TYPE=""

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

# Normalize path for cross-platform (Windows/Linux)
normalize_path() {
    local input="$1"
    # Convert Windows backslashes to forward slashes
    input="${input//\\//}"
    # Remove any double slashes
    input="${input//\/\//\/}"
    echo "$input"
}

# Find CSV files with better cross-platform support
find_csv_files() {
    local search_path="$1"
    local max_depth="$2"
    
    # Clear array
    CSV_FILES=()
    
    # Use find if available, otherwise fallback to ls
    if command -v find >/dev/null 2>&1; then
        while IFS= read -r -d '' file; do
            CSV_FILES+=("$file")
        done < <(find "$search_path" -maxdepth "$max_depth" -type f \
            \( -iname "*.csv" -o -iname "*.list" -o -iname "*list*.txt" \) \
            -print0 2>/dev/null)
    else
        # Fallback for systems without proper find
        for ext in csv CSV list LIST txt TXT; do
            for file in "$search_path"/*."$ext"; do
                [ -f "$file" ] && CSV_FILES+=("$file")
            done
        done
    fi
}

# Find MD5 files with better cross-platform support
find_md5_files() {
    local search_path="$1"
    local max_depth="$2"
    
    # Clear array
    MD5_FILES=()
    
    # Use find if available
    if command -v find >/dev/null 2>&1; then
        while IFS= read -r -d '' file; do
            MD5_FILES+=("$file")
        done < <(find "$search_path" -maxdepth "$max_depth" -type f \
            \( -name "*.md5" -o -name "*checksum*" -o -name "*hash*" -o \
               -name "MD5-*" -o -name "*MD5*" -o -name "manifest*" -o \
               -iname "*md5*" \) -print0 2>/dev/null)
    else
        # Fallback method for systems without proper find
        for pattern in "*.md5" "*checksum*" "*hash*" "MD5-*" "*MD5*" "manifest*"; do
            for file in "$search_path"/$pattern; do
                [ -f "$file" ] && MD5_FILES+=("$file")
            done
        done
    fi
    
    # If no standard files found, check all files for MD5 format
    if [ ${#MD5_FILES[@]} -eq 0 ]; then
        info "No standard MD5 files found. Checking all files for MD5 format..."
        for file in "$search_path"/*; do
            [ -f "$file" ] || continue
            # Skip very large files
            if [ "$(wc -c < "$file" 2>/dev/null || echo 0)" -lt 10000000 ]; then
                if head -3 "$file" 2>/dev/null | grep -q "^[a-f0-9]\{32\}[[:space:]]\+"; then
                    MD5_FILES+=("$file")
                    [ "$VERBOSE" = true ] && info "Found MD5 format in file: $file"
                fi
            fi
        done
    fi
}

# Clean old backup and output files
clean_old_files() {
    local search_path="$1"
    local max_depth="$2"
    local files_found=0
    
    info "Searching for old backup and output files..."
    
    # Find backup files (*.backup.*)
    if command -v find >/dev/null 2>&1; then
        while IFS= read -r -d '' file; do
            if [ -f "$file" ]; then
                info "Found backup file: $file"
                if [ "$DRY_RUN" = false ]; then
                    rm "$file" && success "Deleted: $file" || warning "Could not delete: $file"
                else
                    info "Would delete: $file"
                fi
                files_found=$((files_found + 1))
            fi
        done < <(find "$search_path" -maxdepth "$max_depth" -name "*.backup.*" -print0 2>/dev/null)
        
        # Find output files (md5_update_paths_output_*)
        while IFS= read -r -d '' file; do
            if [ -f "$file" ]; then
                info "Found output file: $file"
                if [ "$DRY_RUN" = false ]; then
                    rm "$file" && success "Deleted: $file" || warning "Could not delete: $file"
                else
                    info "Would delete: $file"
                fi
                files_found=$((files_found + 1))
            fi
        done < <(find "$search_path" -maxdepth "$max_depth" -name "md5_update_paths_output_*" -print0 2>/dev/null)
    else
        # Fallback for systems without find
        for file in "$search_path"/*.backup.* "$search_path"/md5_update_paths_output_*; do
            if [ -f "$file" ]; then
                info "Found old file: $file"
                if [ "$DRY_RUN" = false ]; then
                    rm "$file" && success "Deleted: $file" || warning "Could not delete: $file"
                else
                    info "Would delete: $file"
                fi
                files_found=$((files_found + 1))
            fi
        done
    fi
    
    if [ "$files_found" -eq 0 ]; then
        info "No old backup or output files found."
    else
        success "Found and processed $files_found old files."
    fi
}

# Build new filename based on rename mode - FIXED to preserve original number
build_new_filename() {
    local md5_content="$1"
    local old_path="$2" 
    local dst_path="$3"
    local newname="$4"
    local counter="$5"
    
    local old_filename=$(basename "$old_path")
    
    if [ -n "$newname" ] && [ "$newname" = "rename" ]; then
        # Extract the original number from old filename 
        local original_number=""
        if [[ "$old_filename" =~ _([0-9]{4})\.tif$ ]]; then
            original_number="${BASH_REMATCH[1]}"
        else
            # Fallback: use counter if no number found
            original_number=$(printf "%04d" "$counter")
        fi
        
        # Build prefix from destination path
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
        
        # Use original number instead of generating new sequence
        echo "${prefix}_nr_${dst_folder}_${original_number}.tif"
    elif [ -n "$newname" ] && [ "$newname" != "rename" ]; then
        echo "${newname}.tif"
    else
        echo "$old_filename"
    fi
}

# Process simple rename CSV (full_path_old,full_path_new)
process_renamed_files_csv() {
    local md5_file="$1"
    local csv_file="$2"
    
    info "Processing renamed_files.csv format (full_path_old,full_path_new)"
    
    # Read MD5 file content
    local MD5_CONTENT=$(cat "$md5_file")
    info "MD5 file loaded with $(echo "$MD5_CONTENT" | wc -l) entries"
    
    # Count CSV rows
    TOTAL_ROWS=$(($(wc -l < "$csv_file") - 1))
    info "Number of rename instructions to process: $TOTAL_ROWS"
    
    # Create backup
    local BACKUP_FILE="${md5_file}.backup.$(date +%Y%m%d_%H%M%S)"
    if [ "$DRY_RUN" = false ]; then
        cp "$md5_file" "$BACKUP_FILE"
        success "Backup created: $BACKUP_FILE"
    fi
    
    local UPDATED_MD5_CONTENT="$MD5_CONTENT"
    PROCESSED_CHANGES=0
    TOTAL_CHANGES=0
    
    output_and_log "$(printf '=%.0s' {1..60})"
    info "Starting full path updates in MD5 file..."
    
    # Process CSV file
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        
        # Skip header line
        if [ "$line_num" -eq 1 ]; then
            continue
        fi
        
        line=$(echo "$line" | tr -d '\r')
        [ -z "$line" ] && continue
        
        IFS=',' read -r old_path new_path <<< "$line"
        old_path=$(echo "$old_path" | xargs)
        new_path=$(echo "$new_path" | xargs)
        
        [ -z "$old_path" ] || [ -z "$new_path" ] && continue
        
        PROCESSED_CHANGES=$((PROCESSED_CHANGES + 1))
        show_progress $PROCESSED_CHANGES $TOTAL_ROWS
        output_and_log ""
        info "Processing [$PROCESSED_CHANGES/$TOTAL_ROWS]: $old_path → $new_path"
        
        # Update MD5 content - search for exact full path match
        local temp_content=""
        local found_match=false
        
        while IFS= read -r md5_line; do
            if [[ "$md5_line" =~ ^([a-f0-9]{32})[[:space:]]+(.+)$ ]]; then
                local hash="${BASH_REMATCH[1]}"
                local file_path="${BASH_REMATCH[2]}"
                
                # Compare full path (not just filename)
                if [ "$file_path" = "$old_path" ]; then
                    local new_line="$hash  $new_path"
                    temp_content+="$new_line"$'\n'
                    log_action "Renamed full path in MD5: $file_path → $new_path"
                    TOTAL_CHANGES=$((TOTAL_CHANGES + 1))
                    found_match=true
                    [ "$VERBOSE" = true ] && info "  Match found and updated: $old_path"
                else
                    temp_content+="$md5_line"$'\n'
                fi
            else
                temp_content+="$md5_line"$'\n'
            fi
        done <<< "$UPDATED_MD5_CONTENT"
        
        UPDATED_MD5_CONTENT="$temp_content"
        
        if [ "$found_match" = true ]; then
            success "Successfully renamed: $(basename "$old_path") → $(basename "$new_path")"
        else
            warning "Full path not found in MD5: $old_path"
            [ "$VERBOSE" = true ] && info "  Available paths in MD5 file:"
            [ "$VERBOSE" = true ] && echo "$MD5_CONTENT" | grep -o '[[:space:]].*$' | head -5
        fi
    done < "$csv_file"
    
    # Save results
    save_results "$md5_file" "$BACKUP_FILE"
}

# Process standard path update CSV (Source_Pfad,Ziel_Pfad,New_filenames)
process_path_update_csv() {
    local md5_file="$1"
    local csv_file="$2"
    
    info "Processing path update CSV format (Source_Pfad,Ziel_Pfad,New_filenames)"
    
    # Read MD5 file content
    local MD5_CONTENT=$(cat "$md5_file")
    info "MD5 file loaded with $(echo "$MD5_CONTENT" | wc -l) entries"
    
    # Count CSV rows
    TOTAL_ROWS=$(($(wc -l < "$csv_file") - 1))
    info "Number of path update instructions to process: $TOTAL_ROWS"
    
    # Create backup
    local BACKUP_FILE="${md5_file}.backup.$(date +%Y%m%d_%H%M%S)"
    if [ "$DRY_RUN" = false ]; then
        cp "$md5_file" "$BACKUP_FILE"
        success "Backup created: $BACKUP_FILE"
    fi
    
    local UPDATED_MD5_CONTENT="$MD5_CONTENT"
    PROCESSED_CHANGES=0
    TOTAL_CHANGES=0
    local NEXT_NUM=1
    
    output_and_log "$(printf '=%.0s' {1..60})"
    info "Starting MD5 file updates..."
    
    # Process CSV file
    local line_num=0
    while IFS= read -r LINE; do
        line_num=$((line_num + 1))
        
        # Skip header line
        if [ "$line_num" -eq 1 ]; then
            continue
        fi
        
        LINE=$(echo "$LINE" | tr -d '\r')
        [ -z "$LINE" ] && continue
        
        IFS=$',;\t' read -r SRC DST NEWNAME <<< "$LINE"
        SRC=$(echo "$SRC" | xargs)
        DST=$(echo "$DST" | xargs)
        NEWNAME=$(echo "$NEWNAME" | xargs)
        
        [ -z "$SRC" ] && continue
        
        PROCESSED_CHANGES=$((PROCESSED_CHANGES + 1))
        show_progress $PROCESSED_CHANGES $TOTAL_ROWS
        output_and_log ""
        info "Processing [$PROCESSED_CHANGES/$TOTAL_ROWS]: $SRC → $DST"
        
        local file_counter=1
        local temp_content=""
        
        # Process each line in MD5 file
        while IFS= read -r md5_line; do
            if [[ "$md5_line" =~ ^([a-f0-9]{32})[[:space:]]+(.+)$ ]]; then
                local hash="${BASH_REMATCH[1]}"
                local file_path="${BASH_REMATCH[2]}"
                
                # Check if this file path matches our source pattern
                if [[ "$file_path" == "$SRC/"* ]]; then
                    # Build new filename
                    local new_filename=$(build_new_filename "$UPDATED_MD5_CONTENT" "$file_path" "$DST" "$NEWNAME" "$file_counter")
                    local new_path="${DST}/${new_filename}"
                    local new_line="$hash  $new_path"
                    
                    [ "$VERBOSE" = true ] && info "  Update: $(basename "$file_path") → $(basename "$new_path")"
                    log_action "Updated MD5 entry: $file_path → $new_path"
                    
                    temp_content+="$new_line"$'\n'
                    file_counter=$((file_counter + 1))
                    TOTAL_CHANGES=$((TOTAL_CHANGES + 1))
                else
                    # Keep original line unchanged
                    temp_content+="$md5_line"$'\n'
                fi
            else
                # Keep non-MD5 lines unchanged
                temp_content+="$md5_line"$'\n'
            fi
        done <<< "$UPDATED_MD5_CONTENT"
        
        # Update content for next iteration
        UPDATED_MD5_CONTENT="$temp_content"
        
        if [ "$file_counter" -gt 1 ]; then
            success "Updated $((file_counter - 1)) entries for path: $SRC"
        else
            warning "No matching entries found for path: $SRC"
        fi
    done < "$csv_file"
    
    # Save results
    save_results "$md5_file" "$BACKUP_FILE"
}

# Save results and create report
save_results() {
    local md5_file="$1"
    local backup_file="$2"
    
    output_and_log ""
    show_progress $TOTAL_ROWS $TOTAL_ROWS
    output_and_log ""
    output_and_log ""
    
    # Save updated MD5 file
    if [ "$TOTAL_CHANGES" -gt 0 ]; then
        if [ "$DRY_RUN" = true ]; then
            info "Dry-run mode: Would update $TOTAL_CHANGES entries in MD5 file"
            output_and_log "${YELLOW}Preview of updated MD5 file:${NC}"
            echo "$UPDATED_MD5_CONTENT" | head -10
            if [ "$(echo "$UPDATED_MD5_CONTENT" | wc -l)" -gt 10 ]; then
                info "... (showing first 10 lines)"
            fi
        else
            # Remove trailing empty line
            echo -n "$UPDATED_MD5_CONTENT" | sed '$s/$//' > "$md5_file"
            success "Updated MD5 file saved: $md5_file"
            success "Total entries updated: $TOTAL_CHANGES"
            log_action "MD5 file updated with $TOTAL_CHANGES changes"
        fi
    else
        warning "No matching entries found - MD5 file unchanged"
    fi
    
    # Create detailed report
    {
        echo "=== MD5 Checksum Path Update Report ==="
        echo "Execution time: $(date)"
        echo "Base directory: $BASE_PATH"
        echo "MD5 file: $md5_file"
        echo "CSV instruction file: $CSV_FILE"
        echo "Search subdirectories: $SEARCH_SUBDIRS"
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
        success "Backup of original MD5 file: $backup_file"
    fi
    success "All operations completed!"
}

# Process all MD5 files in directory
process_all_md5_files() {
    local search_depth=1
    if [ "$SEARCH_SUBDIRS" = true ]; then
        search_depth=999
    fi
    
    find_md5_files "$BASE_PATH" $search_depth
    
    if [ ${#MD5_FILES[@]} -eq 0 ]; then
        error_exit "No MD5 files found in directory: $BASE_PATH"
    fi
    
    info "Found ${#MD5_FILES[@]} MD5 files to process:"
    for file in "${MD5_FILES[@]}"; do
        info "  - $file"
    done
    
    echo -ne "Process all these MD5 files? [y/n]: "
    read confirm
    TERMINAL_LOG+=("Process all these MD5 files? [y/n]: $confirm")
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Operation cancelled by user."
        return
    fi
    
    # Ask which type of CSV processing to use for all files
    output_and_log ""
    output_and_log "Select CSV processing type for ALL MD5 files:"
    output_and_log "1) Standard path update (Source_Pfad → Ziel_Pfad + rename)"
    output_and_log "2) Simple full path rename (old_full_path → new_full_path)"
    echo -ne "Enter choice (1-2): "
    read csv_type_choice
    TERMINAL_LOG+=("Enter choice (1-2): $csv_type_choice")
    
    case "$csv_type_choice" in
        1)
            info "Will use standard path update processing for all MD5 files"
            CSV_PROCESSING_TYPE="path_update"
            ;;
        2)
            info "Will use simple full path rename processing for all MD5 files"
            CSV_PROCESSING_TYPE="simple_rename"
            ;;
        *)
            error_exit "Invalid selection: $csv_type_choice"
            ;;
    esac
    
    # Process each MD5 file
    for md5_file in "${MD5_FILES[@]}"; do
        output_and_log "$(printf '=%.0s' {1..80})"
        info "Processing MD5 file: $md5_file"
        
        # Reset counters for each file
        TOTAL_CHANGES=0
        PROCESSED_CHANGES=0
        
        # Process based on selected type
        if [ "$CSV_PROCESSING_TYPE" = "simple_rename" ]; then
            process_renamed_files_csv "$md5_file" "$CSV_FILE"
        else
            process_path_update_csv "$md5_file" "$CSV_FILE"
        fi
        
        output_and_log ""
    done
    
    success "All MD5 files processed successfully!"
}

# Show main menu
show_main_menu() {
    output_and_log "${MAGENTA}=== MD5 Update Script - Main Menu ===${NC}"
    output_and_log "Please select an operation:"
    output_and_log ""
    output_and_log "1) Standard path update (Source_Pfad,Ziel_Pfad,New_filenames)"
    output_and_log "   - Changes directory paths and optionally renames files"
    output_and_log "   - Use 'rename' in New_filenames to auto-generate new names"
    output_and_log ""
    output_and_log "2) Simple full path rename (old_full_path,new_full_path)"
    output_and_log "   - Direct path replacement, no automatic naming"
    output_and_log "   - CSV format: full/path/old.tif,full/path/new.tif"
    output_and_log ""
    output_and_log "3) Process ALL MD5 files in directory"
    output_and_log "   - Apply same CSV operations to all found MD5 files"
    output_and_log "   - You can choose processing type for all files"
    output_and_log ""
    output_and_log "4) Clean old backup and output files"
    output_and_log "5) Exit"
    output_and_log ""
    
    echo -ne "Enter your choice (1-5): "
    read menu_choice
    TERMINAL_LOG+=("Enter your choice (1-5): $menu_choice")
    
    case "$menu_choice" in
        1)
            return 1  # Standard path update
            ;;
        2) 
            return 2  # Simple rename
            ;;
        3)
            return 3  # Process all MD5 files
            ;;
        4)
            return 4  # Clean old files
            ;;
        5)
            info "Exiting script. Goodbye!"
            exit 0
            ;;
        *)
            error_exit "Invalid selection: $menu_choice"
            ;;
    esac
}

# --- WELCOME MESSAGE ---
output_and_log "${BLUE}=== MD5 Checksum Path Update Script v2.0 ===${NC}"
output_and_log "This tool updates file paths in MD5 checksum files without moving actual files."
output_and_log "New features: Cross-platform support, subdirectory search, bulk processing"
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

# Normalize base path for cross-platform
BASE_PATH=$(normalize_path "$BASE_PATH")

# --- CHECK IF DIRECTORY EXISTS ---
[ ! -d "$BASE_PATH" ] && error_exit "Base directory '$BASE_PATH' not found."
cd "$BASE_PATH" || error_exit "Cannot change to directory: $BASE_PATH"

info "Working directory: $(pwd)"

# Create output filename
OUTPUT_FILE="$(basename "$0" .sh)_output_$(date +%Y%m%d_%H%M%S).log"

# --- ASK ABOUT SUBDIRECTORY SEARCH ---
echo -ne "Search for files in subdirectories too? [y/n]: "
read subdir_choice
TERMINAL_LOG+=("Search for files in subdirectories too? [y/n]: $subdir_choice")

if [[ "$subdir_choice" =~ ^[Yy]$ ]]; then
    SEARCH_SUBDIRS=true
    info "Will search in subdirectories"
else
    SEARCH_SUBDIRS=false
    info "Will search only in current directory"
fi

# Set search depth
SEARCH_DEPTH=1
if [ "$SEARCH_SUBDIRS" = true ]; then
    SEARCH_DEPTH=999
fi

# --- SHOW MAIN MENU ---
show_main_menu
OPERATION=$?

# --- HANDLE CLEAN OLD FILES OPERATION ---
if [ "$OPERATION" -eq 4 ]; then
    info "Cleaning old backup and output files..."
    clean_old_files "$BASE_PATH" $SEARCH_DEPTH
    
    # Create simple report for cleaning operation
    {
        echo "=== Old Files Cleanup Report ==="
        echo "Execution time: $(date)"
        echo "Base directory: $BASE_PATH"
        echo "Search subdirectories: $SEARCH_SUBDIRS"
        echo "Dry-run mode: $DRY_RUN"
        echo
        echo "=== Terminal Output ==="
        printf "%s\n" "${TERMINAL_LOG[@]}"
    } > "$OUTPUT_FILE"
    
    success "Cleanup report saved: $OUTPUT_FILE"
    success "Cleanup operation completed!"
    exit 0
fi

# --- FIND CSV FILES ---
find_csv_files "$BASE_PATH" $SEARCH_DEPTH

if [ ${#CSV_FILES[@]} -eq 0 ]; then
    error_exit "No CSV instruction files found in directory: $BASE_PATH"
fi

output_and_log "Available CSV instruction files:"
for i in "${!CSV_FILES[@]}"; do
    output_and_log "$((i+1))) ${CSV_FILES[$i]}"
done

echo -ne "Please select CSV file (1-${#CSV_FILES[@]}): "
read csv_choice
TERMINAL_LOG+=("Please select CSV file (1-${#CSV_FILES[@]}): $csv_choice")

if [[ "$csv_choice" =~ ^[0-9]+$ ]] && [ "$csv_choice" -ge 1 ] && [ "$csv_choice" -le ${#CSV_FILES[@]} ]; then
    CSV_FILE=$(normalize_path "${CSV_FILES[$((csv_choice-1))]}")
    info "Selected CSV file: $CSV_FILE"
else
    error_exit "Invalid selection: $csv_choice"
fi

# --- CHECK CSV FILE ---
[ ! -r "$CSV_FILE" ] && error_exit "Cannot read CSV file: $CSV_FILE"

# --- HANDLE BULK PROCESSING (OPERATION 3) ---
if [ "$OPERATION" -eq 3 ]; then
    info "Processing ALL MD5 files in directory..."
    process_all_md5_files
    exit 0
fi

# --- FIND AND SELECT MD5 FILE FOR SINGLE FILE OPERATIONS ---
find_md5_files "$BASE_PATH" $SEARCH_DEPTH

if [ ${#MD5_FILES[@]} -eq 0 ]; then
    error_exit "No MD5 checksum files found in directory: $BASE_PATH"
fi

output_and_log "Available MD5 checksum files:"
for i in "${!MD5_FILES[@]}"; do
    output_and_log "$((i+1))) ${MD5_FILES[$i]}"
done

echo -ne "Please select MD5 file (1-${#MD5_FILES[@]}): "
read md5_choice
TERMINAL_LOG+=("Please select MD5 file (1-${#MD5_FILES[@]}): $md5_choice")

if [[ "$md5_choice" =~ ^[0-9]+$ ]] && [ "$md5_choice" -ge 1 ] && [ "$md5_choice" -le ${#MD5_FILES[@]} ]; then
    MD5_FILE=$(normalize_path "${MD5_FILES[$((md5_choice-1))]}")
    info "Selected MD5 file: $MD5_FILE"
else
    error_exit "Invalid selection: $md5_choice"
fi

# --- CHECK MD5 FILE ---
[ ! -r "$MD5_FILE" ] && error_exit "Cannot read MD5 file: $MD5_FILE"

# --- PROCESS BASED ON OPERATION TYPE ---
case "$OPERATION" in
    1)
        info "Starting standard path update operation..."
        process_path_update_csv "$MD5_FILE" "$CSV_FILE"
        ;;
    2)
        info "Starting simple filename rename operation..."
        process_renamed_files_csv "$MD5_FILE" "$CSV_FILE"
        ;;
    *)
        error_exit "Unknown operation: $OPERATION"
        ;;
esac

if [ "$DRY_RUN" = true ]; then
    info "This was a dry-run. Remove -n parameter to make actual changes."
fi

output_and_log ""
output_and_log "${GREEN}=== Script Execution Completed Successfully! ===${NC}"