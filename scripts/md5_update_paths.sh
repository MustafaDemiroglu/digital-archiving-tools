#!/usr/bin/env bash
###############################################################################
# Script Name : md5_update_paths.sh
# Version     : 5.5
# Author      : Mustafa Demiroglu
# Purpose     : Update file paths or filenames in MD5 checksum files without moving files.
#               - Mode 1: Standard path update with optional rename rule
#                         CSV (3 cols): Source_Pfad,Ziel_Pfad,New_filenames
#                         - If third col equals 'rename' (case-insensitive):
#                           new filename base is built from Ziel_Pfad as:
#                           "<first>_<second>_nr_<last>_<INDEX>.ext"
#                           (INDEX: preserved from original filename, e.g. 0007)
#               - Mode 2: Simple rename (two-column CSV: old_name,new_name)
#                         Exact match on the path part in MD5 lines.
#               - Mode 3: Process ALL .md5 files in directory (Modes 1 or 2)
#               - Mode 4: Clean old backups and logs
#
# Notes:
#   * MD5 file lines are expected as: "<hash><space><path/filename>"
#   * Paths are updated only in the <path/filename> portion; hash stays intact.
#   * No files are moved/renamed on disk — only MD5 entries are updated.
#
# Tested Shells: bash 4+ (Linux, Git Bash on Windows)
###############################################################################

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Global variables
DRY_RUN=false
VERBOSE=false
BASE_PATH=""
SEARCH_SUBDIRS=false
OUTPUT_FILE=""
TERMINAL_LOG=()
TOTAL_CHANGES=0
PROCESSED_CHANGES=0
TOTAL_ROWS=0

# Helper functions
output_and_log() {
    local message="$1"
    echo -e "$message"
    local plain_message=$(echo -e "$message" | sed 's/\x1B\[[0-9;]*[JKmsu]//g')
    TERMINAL_LOG+=("$plain_message")
}

error_exit() {
    output_and_log "${RED}ERROR:${NC} $1"
    exit 1
}

success() {
    output_and_log "${GREEN}SUCCESS:${NC} $1"
}

info() {
    output_and_log "${BLUE}INFO:${NC} $1"
}

warning() {
    output_and_log "${YELLOW}WARNING:${NC} $1"
}

show_progress() {
    local current=$1
    local total=$2
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    
    printf "\r${CYAN}Progress: [%*s%*s] %d%% (%d/%d)${NC}" \
        $filled "=" $empty " " $percent $current $total
}

# Extract 4-digit number from filename (fixed)
extract_number() {
    local filename="$1"
    if [[ "$filename" =~ _([0-9]{4})\.tif$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "0001"
    fi
}

# Build new filename based on rules (fixed)
build_new_filename() {
    local old_path="$1"
    local dst_path="$2" 
    local newname="$3"
    
    local old_filename=$(basename "$old_path")
    local original_number=$(extract_number "$old_filename")
    
    if [ -n "$newname" ] && [ "$(echo "$newname" | tr '[:upper:]' '[:lower:]')" = "rename" ]; then
        # Auto-generate name from destination path segments
        IFS='/' read -ra SEGMENTS <<< "$dst_path"
        local len=${#SEGMENTS[@]}
        
        if [ $len -ge 3 ]; then
            # Use last 3 segments: first_second_nr_third_INDEX.tif
            local first="${SEGMENTS[$((len-3))]}"
            local second="${SEGMENTS[$((len-2))]}"  
            local third="${SEGMENTS[$((len-1))]}"
            echo "${first}_${second}_nr_${third}_${original_number}.tif"
        elif [ $len -ge 2 ]; then
            # Use last 2 segments: first_nr_second_INDEX.tif
            local first="${SEGMENTS[$((len-2))]}"
            local second="${SEGMENTS[$((len-1))]}"
            echo "${first}_nr_${second}_${original_number}.tif"
        else
            # Single segment: segment_INDEX.tif
            local segment="${SEGMENTS[$((len-1))]}"
            echo "${segment}_${original_number}.tif"
        fi
    elif [ -n "$newname" ] && [ "$(echo "$newname" | tr '[:upper:]' '[:lower:]')" != "rename" ]; then
        # User provided custom name
        echo "${newname}.tif"
    else
        # Keep original filename
        echo "$old_filename"
    fi
}

# Process 3-column CSV (Source_Pfad,Ziel_Pfad,New_filenames)
process_path_update() {
    local md5_file="$1"
    local csv_file="$2"
    
    info "Processing 3-column CSV: Source_Pfad,Ziel_Pfad,New_filenames"
    
    # Read and validate files
    [ ! -f "$md5_file" ] && error_exit "MD5 file not found: $md5_file"
    [ ! -f "$csv_file" ] && error_exit "CSV file not found: $csv_file"
    
    local md5_content=$(cat "$md5_file")
    TOTAL_ROWS=$(($(wc -l < "$csv_file") - 1))
    info "MD5 entries: $(echo "$md5_content" | wc -l), CSV instructions: $TOTAL_ROWS"
    
    # Create backup
    local backup_file="${md5_file}.backup.$(date +%Y%m%d_%H%M%S)"
    [ "$DRY_RUN" = false ] && cp "$md5_file" "$backup_file"
    
    local updated_content="$md5_content"
    PROCESSED_CHANGES=0
    TOTAL_CHANGES=0
    
    # Process CSV
    {
        read # Skip header
        while IFS= read -r line; do
            line=$(echo "$line" | tr -d '\r')
            [ -z "$line" ] && continue
            
            IFS=',' read -r src dst newname <<< "$line"
            src=$(echo "$src" | xargs)
            dst=$(echo "$dst" | xargs)
            newname=$(echo "$newname" | xargs)
            
            [ -z "$src" ] && continue
            
            PROCESSED_CHANGES=$((PROCESSED_CHANGES + 1))
            show_progress $PROCESSED_CHANGES $TOTAL_ROWS
            
            [ "$VERBOSE" = true ] && echo "" && info "Processing: $src → $dst"
            
            # Update matching entries
            local temp_content=""
            while IFS= read -r md5_line; do
                if [[ "$md5_line" =~ ^([a-f0-9]{32})[[:space:]]+(.+)$ ]]; then
                    local hash="${BASH_REMATCH[1]}"
                    local file_path="${BASH_REMATCH[2]}"
                    
                    if [[ "$file_path" == "$src/"* ]]; then
                        local new_filename=$(build_new_filename "$file_path" "$dst" "$newname")
                        local new_path="${dst}/${new_filename}"
                        temp_content+="$hash  $new_path"$'\n'
                        TOTAL_CHANGES=$((TOTAL_CHANGES + 1))
                        [ "$VERBOSE" = true ] && info "  Updated: $(basename "$file_path") → $(basename "$new_path")"
                    else
                        temp_content+="$md5_line"$'\n'
                    fi
                else
                    temp_content+="$md5_line"$'\n'
                fi
            done <<< "$updated_content"
            
            updated_content="$temp_content"
        done
    } < "$csv_file"
    
    save_results "$md5_file" "$backup_file" "$updated_content"
}

# Process 2-column CSV (old_full_path,new_full_path)
process_simple_rename() {
    local md5_file="$1"
    local csv_file="$2"
    
    info "Processing 2-column CSV: old_full_path,new_full_path"
    
    # Read and validate files
    [ ! -f "$md5_file" ] && error_exit "MD5 file not found: $md5_file"
    [ ! -f "$csv_file" ] && error_exit "CSV file not found: $csv_file"
    
    local md5_content=$(cat "$md5_file")
    TOTAL_ROWS=$(($(wc -l < "$csv_file") - 1))
    info "MD5 entries: $(echo "$md5_content" | wc -l), CSV instructions: $TOTAL_ROWS"
    
    # Create backup
    local backup_file="${md5_file}.backup.$(date +%Y%m%d_%H%M%S)"
    [ "$DRY_RUN" = false ] && cp "$md5_file" "$backup_file"
    
    local updated_content="$md5_content"
    PROCESSED_CHANGES=0
    TOTAL_CHANGES=0
    
    # Process CSV
    {
        read # Skip header
        while IFS= read -r line; do
            line=$(echo "$line" | tr -d '\r')
            [ -z "$line" ] && continue
            
            IFS=',' read -r old_path new_path <<< "$line"
            old_path=$(echo "$old_path" | xargs)
            new_path=$(echo "$new_path" | xargs)
            
            [ -z "$old_path" ] || [ -z "$new_path" ] && continue
            
            PROCESSED_CHANGES=$((PROCESSED_CHANGES + 1))
            show_progress $PROCESSED_CHANGES $TOTAL_ROWS
            
            [ "$VERBOSE" = true ] && echo "" && info "Processing: $old_path → $new_path"
            
            # Replace exact path matches
            local temp_content=""
            local found_match=false
            while IFS= read -r md5_line; do
                if [[ "$md5_line" =~ ^([a-f0-9]{32})[[:space:]]+(.+)$ ]]; then
                    local hash="${BASH_REMATCH[1]}"
                    local file_path="${BASH_REMATCH[2]}"
                    
                    if [ "$file_path" = "$old_path" ]; then
                        temp_content+="$hash  $new_path"$'\n'
                        TOTAL_CHANGES=$((TOTAL_CHANGES + 1))
                        found_match=true
                        [ "$VERBOSE" = true ] && info "  Match found and updated"
                    else
                        temp_content+="$md5_line"$'\n'
                    fi
                else
                    temp_content+="$md5_line"$'\n'
                fi
            done <<< "$updated_content"
            
            updated_content="$temp_content"
            [ "$found_match" = false ] && [ "$VERBOSE" = true ] && warning "  No match found for: $old_path"
        done
    } < "$csv_file"
    
    save_results "$md5_file" "$backup_file" "$updated_content"
}

# Save results and create report
save_results() {
    local md5_file="$1"
    local backup_file="$2" 
    local updated_content="$3"
    
    echo ""
    show_progress $TOTAL_ROWS $TOTAL_ROWS
    echo -e "\n"
    
    if [ "$TOTAL_CHANGES" -gt 0 ]; then
        if [ "$DRY_RUN" = true ]; then
            info "DRY-RUN: Would update $TOTAL_CHANGES entries"
            echo "$updated_content" | head -5
        else
            echo -n "$updated_content" | sed '$s/$//' > "$md5_file"
            success "Updated MD5 file with $TOTAL_CHANGES changes"
            success "Backup saved: $backup_file"
        fi
    else
        warning "No matching entries found - no changes made"
    fi
    
    # Create report
    {
        echo "=== MD5 Update Report ==="
        echo "Time: $(date)"
        echo "MD5 file: $md5_file"
        echo "CSV file: ${CSV_FILE:-N/A}"
        echo "Changes made: $TOTAL_CHANGES"
        echo "Dry-run: $DRY_RUN"
        echo ""
        printf "%s\n" "${TERMINAL_LOG[@]}"
    } > "$OUTPUT_FILE"
    
    success "Report saved: $OUTPUT_FILE"
}

# Find files
find_files() {
    local search_path="$1"
    local pattern="$2"
    local depth=1
    [ "$SEARCH_SUBDIRS" = true ] && depth=999
    
    FILES=()
    if command -v find >/dev/null 2>&1; then
        while IFS= read -r -d '' file; do
            FILES+=("$file")
        done < <(find "$search_path" -maxdepth "$depth" -type f -name "$pattern" -print0 2>/dev/null)
    else
        for file in "$search_path"/$pattern; do
            [ -f "$file" ] && FILES+=("$file")
        done
    fi
}

# Process all MD5 files
process_all_md5() {
    find_files "$BASE_PATH" "*.md5"
    local md5_files=("${FILES[@]}")
    
    [ ${#md5_files[@]} -eq 0 ] && error_exit "No MD5 files found"
    
    info "Found ${#md5_files[@]} MD5 files:"
    for file in "${md5_files[@]}"; do
        info "  - $file"
    done
    
    echo -ne "Process all files? [y/n]: "
    read confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { info "Cancelled."; return; }
    
    # Choose processing type
    output_and_log "Select processing type for ALL MD5 files:"
    output_and_log "1) Path update (Source_Pfad → Ziel_Pfad + rename)"
    output_and_log "2) Simple rename (old_full_path → new_full_path)"
    echo -ne "Choice (1-2): "
    read process_type
    
    case "$process_type" in
        1) info "Using path update processing" ;;
        2) info "Using simple rename processing" ;;
        *) error_exit "Invalid choice: $process_type" ;;
    esac
    
    # Process each file
    for md5_file in "${md5_files[@]}"; do
        output_and_log "$(printf '=%.0s' {1..60})"
        info "Processing: $md5_file"
        
        case "$process_type" in
            1) process_path_update "$md5_file" "$CSV_FILE" ;;
            2) process_simple_rename "$md5_file" "$CSV_FILE" ;;
        esac
    done
    
    success "All MD5 files processed!"
}

# Clean old files
clean_old_files() {
    info "Cleaning old backup and output files..."
    
    local patterns=("*.backup.*" "md5_update_paths_output_*")
    local files_found=0
    
    for pattern in "${patterns[@]}"; do
        find_files "$BASE_PATH" "$pattern"
        for file in "${FILES[@]}"; do
            info "Found: $file"
            if [ "$DRY_RUN" = false ]; then
                rm "$file" && success "Deleted: $file"
            else
                info "Would delete: $file"
            fi
            files_found=$((files_found + 1))
        done
    done
    
    [ "$files_found" -eq 0 ] && info "No old files found"
}



# MAIN EXECUTION
info "MD5 Checksum Path Update Script"

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=true; info "Dry-run mode enabled"; shift ;;
        -v|--verbose) VERBOSE=true; info "Verbose mode enabled"; shift ;;
        -h|--help)
            echo "Usage: $0 [-n|--dry-run] [-v|--verbose] [base_path]"
            echo "  -n, --dry-run   Preview changes without saving"
            echo "  -v, --verbose   Show detailed output"
            exit 0 ;;
        *) BASE_PATH="$1"; shift ;;
    esac
done

# Get working directory
if [ -z "$BASE_PATH" ]; then
    echo -ne "Use current directory ($(pwd))? [y/n]: "
    read choice
    [[ "$choice" =~ ^[Yy]$ ]] && BASE_PATH=$(pwd) || {
        echo -ne "Enter directory path: "
        read BASE_PATH
    }
fi

[ ! -d "$BASE_PATH" ] && error_exit "Directory not found: $BASE_PATH"
cd "$BASE_PATH" || error_exit "Cannot change to: $BASE_PATH"
info "Working in: $(pwd)"

# Subdirectory search option
echo -ne "Search in subdirectories? [y/n]: "
read subdir_choice
[[ "$subdir_choice" =~ ^[Yy]$ ]] && SEARCH_SUBDIRS=true

OUTPUT_FILE="md5_update_output_$(date +%Y%m%d_%H%M%S).log"

# Main menu loop
output_and_log "${BLUE}=== MD5 Path Update Script v5.0 ===${NC}"
output_and_log "Select operation:"
output_and_log "1) Path update with rename (3-column CSV: Source_Pfad,Ziel_Pfad,New_filenames)"
output_and_log "2) Simple path/filename change (2-column CSV: old_full_path,new_full_path)" 
output_and_log "3) Process ALL MD5 files in directory"
output_and_log "4) Clean old backup files"
output_and_log "5) Exit"
output_and_log ""

echo -ne "Choice (1-5): "
read choice
TERMINAL_LOG+=("Choice (1-5): $choice")

case "$choice" in
    1|2|3)
        # Find CSV files
        find_files "$BASE_PATH" "*.csv"
        csv_files=("${FILES[@]}")
        
        [ ${#csv_files[@]} -eq 0 ] && error_exit "No CSV files found"
        
        info "Available CSV files:"
        for i in "${!csv_files[@]}"; do
            info "$((i+1))) ${csv_files[$i]}"
        done
        
        echo -ne "Select CSV file (1-${#csv_files[@]}): "
        read csv_choice
        
        if [[ "$csv_choice" =~ ^[0-9]+$ ]] && [ "$csv_choice" -ge 1 ] && [ "$csv_choice" -le ${#csv_files[@]} ]; then
            CSV_FILE="${csv_files[$((csv_choice-1))]}"
            info "Selected: $CSV_FILE"
        else
            error_exit "Invalid selection: $csv_choice"
        fi
        
        case "$choice" in
            1)
                # Find MD5 files for single processing
                find_files "$BASE_PATH" "*.md5"
                md5_files=("${FILES[@]}")
                
                [ ${#md5_files[@]} -eq 0 ] && error_exit "No MD5 files found"
                
                info "Available MD5 files:"
                for i in "${!md5_files[@]}"; do
                    info "$((i+1))) ${md5_files[$i]}"
                done
                
                echo -ne "Select MD5 file (1-${#md5_files[@]}): "
                read md5_choice
                
                if [[ "$md5_choice" =~ ^[0-9]+$ ]] && [ "$md5_choice" -ge 1 ] && [ "$md5_choice" -le ${#md5_files[@]} ]; then
                    MD5_FILE="${md5_files[$((md5_choice-1))]}"
                    process_path_update "$MD5_FILE" "$CSV_FILE"
                else
                    error_exit "Invalid selection: $md5_choice"
                fi
                ;;
            2)
                # Find MD5 files for single processing
                find_files "$BASE_PATH" "*.md5"
                md5_files=("${FILES[@]}")
                
                [ ${#md5_files[@]} -eq 0 ] && error_exit "No MD5 files found"
                
                info "Available MD5 files:"
                for i in "${!md5_files[@]}"; do
                    info "$((i+1))) ${md5_files[$i]}"
                done
                
                echo -ne "Select MD5 file (1-${#md5_files[@]}): "
                read md5_choice
                
                if [[ "$md5_choice" =~ ^[0-9]+$ ]] && [ "$md5_choice" -ge 1 ] && [ "$md5_choice" -le ${#md5_files[@]} ]; then
                    MD5_FILE="${md5_files[$((md5_choice-1))]}"
                    process_simple_rename "$MD5_FILE" "$CSV_FILE"
                else
                    error_exit "Invalid selection: $md5_choice"
                fi
                ;;
            3) process_all_md5 ;;
        esac
        ;;
    4) clean_old_files ;;
    5) info "Goodbye!"; exit 0 ;;
    *) error_exit "Invalid choice: $choice" ;;
esac

success "Operation completed successfully!"
[ "$DRY_RUN" = true ] && info "This was a dry-run. Remove -n to make actual changes."