#!/usr/bin/env bash
###############################################################################
# Script Name: update_md5checksum.sh 
# Version 9.5.1
# Author: Mustafa Demiroglu
#
# Description:
#   This script updates MD5 checksum files by changing file paths and names
#   according to instructions in a CSV file, without moving actual files. 
#   If Ziel_Pfad and New_filenames are empty, entries matching Source_Pfad will be deleted
#   Deletion removes complete MD5 lines (hash + file path)
#
# Performance Improvements:
#   - Single-pass processing instead of nested loops
#   - Associative arrays for O(1) lookups
#   - Batch file operations
#   - Memory-efficient streaming for large files
#
# Usage:
#   ./md5_update_paths.sh [-n] [-v] [base_path]
#
# Options:
#   -n   Dry-run mode (show changes but don't save)
#   -v   Verbose mode (detailed output)
#
###############################################################################

# --- COLORS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# --- VARIABLES ---
DRY_RUN=false
VERBOSE=false
BASE_PATH=""
SEARCH_SUBDIRS=false
CSV_PROCESSED=false

# --- AUDIT COUNTERS ---
TOTAL_CHANGES=0
TOTAL_MD5_LINES=0
SKIPPED_NO_MATCH=0
SKIPPED_INVALID_MD5=0

# --- ARRAYS ---
declare -a TERMINAL_LOG
declare -a LOG_ACTIONS
declare -a CSV_FILES
declare -a MD5_FILES
declare -A PATH_MAP           # Associative array for O(1) path lookups
declare -A DELETION_PATHS     # Paths to delete
declare -A FILE_COUNTERS      # Counter for each destination path

# --- HELPER FUNCTIONS ---

output_and_log() {
    local message="$1"
    echo -e "$message"
    local plain_message=$(echo -e "$message" | sed 's/\x1B\[[0-9;]*[JKmsu]//g')
    TERMINAL_LOG+=("$plain_message")
}

log_action() {
    local action="$1"
    local status="${2:-SUCCESS}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    LOG_ACTIONS+=("[$timestamp] [$status] $action")
}

error_exit() {
    output_and_log "${RED}ERROR:${NC} $1"
    exit 1
}

warning() {
    output_and_log "${YELLOW}WARNING:${NC} $1"
}

success() {
    output_and_log "${GREEN}SUCCESS:${NC} $1"
}

info() {
    output_and_log "${BLUE}INFO:${NC} $1"
}

show_progress() {
    local current=$1
    local total=$2
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    
    printf "\r${CYAN}Progress: [%*s%*s] %d%% (%d/%d)${NC}" \
        $filled "$(printf '%*s' $filled | tr ' ' '=')" \
        $empty "" $percent $current $total
}

normalize_path() {
    local input="$1"
    input="${input//\\//}"
    input="${input//\/\//\/}"
    echo "$input"
}

find_csv_files() {
    local search_path="$1"
    local max_depth="$2"
    
    CSV_FILES=()
    
    if command -v find >/dev/null 2>&1; then
        while IFS= read -r -d '' file; do
            CSV_FILES+=("$file")
        done < <(find "$search_path" -maxdepth "$max_depth" -type f \
            \( -iname "*.csv" -o -iname "*.list" -o -iname "*list*.txt" \) \
            -print0 2>/dev/null)
    else
        for ext in csv CSV list LIST txt TXT; do
            for file in "$search_path"/*."$ext"; do
                [ -f "$file" ] && CSV_FILES+=("$file")
            done
        done
    fi
}

find_md5_files() {
    local search_path="$1"
    local max_depth="$2"
    
    MD5_FILES=()
    
    if command -v find >/dev/null 2>&1; then
        while IFS= read -r -d '' file; do
            MD5_FILES+=("$file")
        done < <(find "$search_path" -maxdepth "$max_depth" -type f \
            \( -name "*.md5" -o -name "*checksum*" -o -name "*hash*" -o \
               -name "MD5-*" -o -name "*MD5*" -o -name "manifest*" -o \
               -iname "*md5*" \) -print0 2>/dev/null)
    else
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
            if [ "$(wc -c < "$file" 2>/dev/null || echo 0)" -lt 10000000 ]; then
                if head -3 "$file" 2>/dev/null | grep -q "^[a-f0-9]\{32\}[[:space:]]\+"; then
                    MD5_FILES+=("$file")
                    [ "$VERBOSE" = true ] && info "Found MD5 format in file: $file"
                fi
            fi
        done
    fi
}

build_new_filename() {
    local old_path="$1" 
    local dst_path="$2"
    local newname="$3"
    local counter="$4"
    
    local old_filename=$(basename "$old_path")
    
    if [ -n "$newname" ] && [ "$newname" = "rename" ]; then
        # Extract the original number from old filename 
        local original_number=""
        if [[ "$old_filename" =~ _([0-9]{4})\.tif$ ]]; then
            original_number="${BASH_REMATCH[1]}"
        else
            original_number=$(printf "%04d" "$counter")
        fi
        
        # Build prefix from destination path
        IFS='/' read -ra DST_PARTS <<< "$dst_path"
        local L=${#DST_PARTS[@]}
        local prefix=""
        local dst_folder=""
        
        if [ $L -ge 3 ]; then
            prefix="${DST_PARTS[$L-3]}_${DST_PARTS[$L-2]}"
            dst_folder="${DST_PARTS[$L-1]}"
        elif [ $L -ge 2 ]; then
            prefix="${DST_PARTS[$L-2]}"
            dst_folder="${DST_PARTS[$L-1]}"
        else
            prefix="file"
            dst_folder="folder"
        fi
        
        echo "${prefix}_nr_${dst_folder}_${original_number}.tif"
    elif [ -n "$newname" ] && [ "$newname" != "rename" ]; then
        echo "${newname}.tif"
    else
        echo "$old_filename"
    fi
}

###############################################################################
# Function: load_csv_instructions
# Description:
#   Load CSV file into memory for quick lookup
#   For simple_rename: reads old_path,new_path format
#   For path_update: reads src,dst,newname format
###############################################################################
load_csv_instructions() {
    local csv_file="$1"
    local csv_type="$2"
    
    info "Loading CSV instructions into memory..."
    
    # Clear arrays
    unset PATH_MAP
    unset DELETION_PATHS
    unset FILE_COUNTERS
    declare -gA PATH_MAP
    declare -gA DELETION_PATHS
    declare -gA FILE_COUNTERS
    
    local line_count=0
    {
        read # Skip header
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line//$'\r'/}" 			# Remove Windows line endings
            [ -z "$line" ] && continue
            
            line_count=$((line_count + 1))
            
            if [ "$csv_type" = "simple_rename" ]; then                 # Simple format: old_path,new_path or old_path<tab>new_path
                IFS=$',;\t' read -r old_path new_path <<< "$line"
                old_path="${old_path#"${old_path%%[![:space:]]*}"}"
                old_path="${old_path%"${old_path##*[![:space:]]}"}"
                new_path="${new_path#"${new_path%%[![:space:]]*}"}"
                new_path="${new_path%"${new_path##*[![:space:]]}"}"
                
                # Debug output for troubleshooting
                #[ "$VERBOSE" = true ] && info "Parsing line $line_count: '$old_path' -> '$new_path'"
                
                if [ -n "$old_path" ] && [ -n "$new_path" ]; then	    # Add to map if both values exist
                    PATH_MAP["$old_path"]="$new_path"
                #else
                #   [ "$VERBOSE" = true ] && warning "Skipping invalid line $line_count: $line"
                fi
            else 														# Path update format: src,dst,newname
                IFS=$',;\t' read -r src dst newname <<< "$line"
                
				src="${src#"${src%%[![:space:]]*}"}"
                src="${src%"${src##*[![:space:]]}"}"
                dst="${dst#"${dst%%[![:space:]]*}"}"
                dst="${dst%"${dst##*[![:space:]]}"}"
                newname="${newname#"${newname%%[![:space:]]*}"}"
                newname="${newname%"${newname##*[![:space:]]}"}"
                
                [ -z "$src" ] && continue
                
                # Check if this is a deletion operation (empty dst and newname)
                if [ -z "$dst" ] && [ -z "$newname" ]; then
                    DELETION_PATHS["$src"]=1
                else
                    PATH_MAP["$src"]="${dst}|${newname}"
                    FILE_COUNTERS["$src"]=1
                fi
            fi
        done
    } < "$csv_file"
    
    info "Loaded $line_count CSV instructions"
	if [ "$csv_type" = "simple_rename" ]; then
        info "Simple renames: ${#PATH_MAP[@]}"
    else
        info "Path updates: ${#PATH_MAP[@]}, Deletions: ${#DELETION_PATHS[@]}"
    fi

	# Show first few mappings if verbose to a better debugging
    #if [ "$VERBOSE" = true ] && [ ${#PATH_MAP[@]} -gt 0 ]; then
    #   info "First few path mappings:"
    #    local count=0
    #    for key in "${!PATH_MAP[@]}"; do
    #        info "  '$key' -> '${PATH_MAP[$key]}'"
    #        count=$((count + 1))
    #        [ $count -ge 10 ] && break
    #    done
    #fi
	
	# Audit: CSV rules loaded but no MD5 processed yet
    #for src in "${!PATH_MAP[@]}"; do
    #    log_action "CSV rule loaded: $src → ${PATH_MAP[$src]}" "INFO"
    #done
	
	#  speed up: Instead log summary only
    log_action "CSV loaded: ${#PATH_MAP[@]} updates, ${#DELETION_PATHS[@]} deletions" "INFO"
	
	# Global stop: If CSV has no actionable instructions, terminate script
	if [ "$line_count" -eq 0 ]; then
		info "CSV contains 0 instructions → no work to do. Stopping script."
		log_action "CSV empty → script stopped logically." "INFO"
		exit 0
	fi
}

###############################################################################
# Function: process_renamed_files_csv
# Description:
#   Simple rename process for MD5 files
#   Reads CSV: old_path,new_path
#   Finds old_path in MD5 file replaces with new_path
#   Hash stays the same
###############################################################################
process_renamed_files_csv() {
    local md5_file="$1"
    local csv_file="$2"
	local csv_tmp="${csv_file}.tmp"
    
    info "Processing renamed_files.csv format (full_path_old,full_path_new)"
    
    # Load CSV instructions
    load_csv_instructions "$csv_file" "simple_rename"
    
    local total_lines
    total_lines=$(wc -l < "$md5_file")
    info "MD5 file has $total_lines entries"
    
    # Create backup
    local backup_file="${md5_file}.backup.$(date +%Y%m%d_%H%M%S)"
    if [ "$DRY_RUN" = false ]; then
        cp "$md5_file" "$backup_file"
        success "Backup created: $backup_file"
    fi
    
    TOTAL_CHANGES=0
	TOTAL_MD5_LINES=0
	
	# Track actually renamed paths
    declare -A RENAMED_PATHS=()
    
    info "Starting MD5 file processing..."
    
    # Create temporary file for output
    local temp_file
    temp_file=$(mktemp)
    
    local line_num=0
    
	{
        while IFS= read -r md5_line; do
            line_num=$((line_num + 1))
            TOTAL_MD5_LINES=$((TOTAL_MD5_LINES + 1))

			# Show progress every 5000 lines
			if [ $((line_num % 5000)) -eq 0 ]; then
				show_progress $line_num $total_lines
			fi

            # Parse MD5 line: <hash><space><path>
            if [[ "$md5_line" =~ ^([a-f0-9A-F]{32})[[:space:]]+(.+)$ ]]; then
                local hash="${BASH_REMATCH[1]}"
                local file_path="${BASH_REMATCH[2]}"

                # Normalize path (pure bash trim, no sed)
                file_path="${file_path//$'\r'/}"
                file_path="${file_path%"${file_path##*[![:space:]]}"}"

                # Check if this path is in our map
                if [[ -n "${PATH_MAP[$file_path]+_}" ]]; then
                    local new_path="${PATH_MAP[$file_path]}"

                    echo "$hash  $new_path"

                    log_action "Renamed full path in MD5: $file_path → $new_path"

                    TOTAL_CHANGES=$((TOTAL_CHANGES + 1))
                    RENAMED_PATHS["$file_path"]=1

                    [ "$VERBOSE" = true ] && \
                        success "Line $line_num: $file_path → $new_path"
                else
                    echo "$md5_line"
                fi
            else
                echo "$md5_line"
            fi

        done < "$md5_file"
    } > "$temp_file"
    
    show_progress $total_lines $total_lines
    echo ""
    	
	# CSV CLEANUP: remove only successfully used rows
    if [ "$TOTAL_CHANGES" -eq 0 ]; then
        log_action "No renames applied → CSV left untouched"
        rm -f "$csv_tmp"
    else
		log_action "Cleaning CSV: removing processed rename entries"

        while IFS=';' read -r old_path rest; do
            if [[ -z "${RENAMED_PATHS[$old_path]+_}" ]]; then
                echo "$old_path;$rest" >> "$csv_tmp"
            else
                log_action "CSV row removed (rename applied): $old_path"
            fi
        done < "$csv_file"

        mv "$csv_tmp" "$csv_file"
        log_action "CSV updated: processed rows removed"
    fi
	
	save_results "$md5_file" "$backup_file" "$temp_file"
}

# Path update processing
process_path_update_csv() {
    local md5_file="$1"
    local csv_file="$2"
    
    info "Processing path update CSV format (Source_Pfad,Ziel_Pfad,New_filenames)"
    
    # Load CSV instructions
    load_csv_instructions "$csv_file" "path_update"
    
    local total_lines
    total_lines=$(wc -l < "$md5_file")
    info "MD5 file has $total_lines entries"
    
    # Create backup
    local backup_file="${md5_file}.backup.$(date +%Y%m%d_%H%M%S)"
    if [ "$DRY_RUN" = false ]; then
        cp "$md5_file" "$backup_file"
        success "Backup created: $backup_file"
    fi
    
    TOTAL_CHANGES=0
    
    info "Starting MD5 file processing..."
    
    # Create temporary file for output
    local temp_file
    temp_file=$(mktemp)
    
	# Fast lookup Maps (3 or 4 -level path index)
	declare -A FAST_DELETE
    declare -A FAST_UPDATE

    for p in "${!DELETION_PATHS[@]}"; do
        FAST_DELETE["$p"]=1
    done

    for p in "${!PATH_MAP[@]}"; do
        FAST_UPDATE["$p"]="${PATH_MAP[$p]}"
    done
	
    # Reset file counters for each source path
    local src_path
    for src_path in "${!PATH_MAP[@]}"; do
        FILE_COUNTERS["$src_path"]=1
    done
    
    # Single pass through MD5 file
    local line_num=0
    while IFS= read -r md5_line; do
        line_num=$((line_num + 1))
		TOTAL_MD5_LINES=$((TOTAL_MD5_LINES + 1))
        
        # Show progress every 5000 lines
        if [ $((line_num % 5000)) -eq 0 ]; then
            show_progress $line_num $total_lines
        fi
        
        if [[ "$md5_line" =~ ^([a-f0-9]{32})[[:space:]]+(.+)$ ]]; then
            local hash="${BASH_REMATCH[1]}"
            local file_path="${BASH_REMATCH[2]}"
            local line_handled=false

			# Extract first 3 path segments as lookup key without secure or fremd
			local key
			IFS='/' read -ra PARTS <<< "$file_path"
			unset 'PARTS[${#PARTS[@]}-1]'
			dir_count=${#PARTS[@]}
			if (( dir_count >= 4 )); then
				key="${PARTS[0]}/${PARTS[1]}/${PARTS[2]}/${PARTS[3]}"
			else
				key="${PARTS[0]}/${PARTS[1]}/${PARTS[2]}"
			fi
			
            # Check for deletion first
            if [[ -n "${FAST_DELETE[$key]}" ]]; then
                #[ "$VERBOSE" = true ] && [ $((TOTAL_CHANGES % 100)) -eq 0 ] && info "Deleted: $file_path"
                #log_action "Deleted MD5 entry: $file_path"
                TOTAL_CHANGES=$((TOTAL_CHANGES + 1))
                line_handled=true
            fi

			# Check for path updates
			if [ "$line_handled" = false ] && [[ -n "${FAST_UPDATE[$key]}" ]]; then
                IFS='|' read -r dst newname <<< "${FAST_UPDATE[$key]}"

                local counter=${FILE_COUNTERS["$key"]}
                local new_filename
                new_filename=$(build_new_filename "$file_path" "$dst" "$newname" "$counter")
                local new_path="${dst}/${new_filename}"

                echo "$hash  $new_path" >> "$temp_file"

                FILE_COUNTERS["$key"]=$((counter + 1))

                #[ "$VERBOSE" = true ] && [ $((TOTAL_CHANGES % 100)) -eq 0 ] && info "Updated: $(basename "$file_path") → $(basename "$new_path")"
                #log_action "Updated MD5 entry: $file_path → $new_path"
                TOTAL_CHANGES=$((TOTAL_CHANGES + 1))
                line_handled=true
            fi
  
    		# Keep original line if nothing matched  
			if [ "$line_handled" = false ]; then
            	echo "$md5_line" >> "$temp_file"
				SKIPPED_INVALID_MD5=$((SKIPPED_INVALID_MD5 + 1))
				#log_action "Skipped (no CSV match): $file_path" "INFO"
        	fi
		#else
			#log_action "Invalid MD5 line format (line $line_num): $md5_line" "ERROR"
		fi
    done < "$md5_file"
    
    show_progress $total_lines $total_lines
    echo ""
	
    save_results "$md5_file" "$backup_file" "$temp_file"
}

save_results() {
    local md5_file="$1"
    local backup_file="$2"
    local temp_file="$3"
    
    echo ""
    
    # Save updated MD5 file
    if [ "$TOTAL_CHANGES" -gt 0 ]; then
		CSV_PROCESSED=true
        if [ "$DRY_RUN" = true ]; then
            info "Dry-run mode: Would update $TOTAL_CHANGES entries in MD5 file"
            output_and_log "${YELLOW}Preview of updated MD5 file:${NC}"
            head -10 "$temp_file"
            local temp_lines
            temp_lines=$(wc -l < "$temp_file")
            if [ "$temp_lines" -gt 10 ]; then
                info "... (showing first 10 lines of $temp_lines total)"
            fi
        else
            # Use efficient file copy
            mv "$temp_file" "$md5_file"
            success "Updated MD5 file saved: $md5_file"
            success "Total entries updated: $TOTAL_CHANGES"
            log_action "MD5 file updated with $TOTAL_CHANGES changes"
        fi
    else
        warning "No matching entries found - MD5 file unchanged, because of that $backup_file deleted"
		rm -f "$backup_file"
    fi
    
	rm -f "$temp_file"
	
    # Create detailed report
    local output_file="md5_update_paths_output_$(date +%Y%m%d_%H%M%S).log"
    {
        echo "=== MD5 Checksum Path Update Report ==="
        echo "Execution time: $(date)"
        echo "Base directory: $BASE_PATH"
        echo "MD5 file: $md5_file"
        echo "Search subdirectories: $SEARCH_SUBDIRS"
        echo "Dry-run mode: $DRY_RUN"
        echo "Verbose mode: $VERBOSE"
        echo "Total MD5 entries updated: $TOTAL_CHANGES"
        echo
        if [ "$DRY_RUN" = true ]; then
            echo "=== DRY-RUN MODE - NO ACTUAL CHANGES WERE MADE ==="
            echo "The following shows what would happen in real execution:"
            echo
        fi
        echo "=== Performance Summary ==="
        echo "Processing method: Single-pass with associative arrays"
        echo "Memory usage: Optimized with temporary files"
        echo
        echo "=== Complete Terminal Output ==="
        printf "%s\n" "${TERMINAL_LOG[@]}"
        echo
        echo "=== Operation Summary ==="
        printf "%s\n" "${LOG_ACTIONS[@]}"
		echo
        echo "=== Audit Summary ==="
        echo "Total MD5 lines read        : $TOTAL_MD5_LINES"
        echo "Total entries updated       : $TOTAL_CHANGES"
        echo "Skipped (no CSV match)      : $SKIPPED_NO_MATCH"
        echo "Skipped (invalid MD5 lines) : $SKIPPED_INVALID_MD5"
    } > "$output_file"
    
    success "Detailed report saved: $output_file"
    if [ "$DRY_RUN" = false ] && [ "$TOTAL_CHANGES" -gt 0 ]; then
        success "Backup of original MD5 file: $backup_file"
    fi
    success "All operations completed!"
}

clean_old_files() {
    local search_path="$1"
    local max_depth="$2"
    local files_found=0
    
    info "Searching for old backup and output files..."
    
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
    fi
    
    if [ "$files_found" -eq 0 ]; then
        info "No old backup or output files found."
    else
        success "Found and processed $files_found old files."
    fi
}

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
    read -r confirm
    TERMINAL_LOG+=("Process all these MD5 files? [y/n]: $confirm")
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        info "Operation cancelled by user."
        return
    fi
    
    # Ask which type of CSV processing to use for all files
    echo ""
    output_and_log "Select CSV processing type for ALL MD5 files:"
    output_and_log "1) Standard path update (Source_Pfad → Ziel_Pfad + rename)"
    output_and_log "2) Simple full path rename (old_full_path → new_full_path)"
    echo -ne "Enter choice (1-2): "
    read -r csv_type_choice
    TERMINAL_LOG+=("Enter choice (1-2): $csv_type_choice")
    
    local csv_processing_type
    case "$csv_type_choice" in
        1)
            info "Will use standard path update processing for all MD5 files"
            csv_processing_type="path_update"
            ;;
        2)
            info "Will use simple full path rename processing for all MD5 files"
            csv_processing_type="simple_rename"
            ;;
        *)
            error_exit "Invalid selection: $csv_type_choice"
            ;;
    esac
    
    # Process each MD5 file
    local csv_file="$1"
    for md5_file in "${MD5_FILES[@]}"; do
        output_and_log "$(printf '=%.0s' {1..80})"
        info "Processing MD5 file: $md5_file"
        
        # Reset counters for each file
        TOTAL_CHANGES=0
        
        # Process based on selected type - USING FUNCTIONS
        if [ "$csv_processing_type" = "simple_rename" ]; then
            process_renamed_files_csv "$md5_file" "$csv_file"
        else
            process_path_update_csv "$md5_file" "$csv_file"
        fi
        
        echo ""
    done
    
    success "All MD5 files processed successfully!"
}

show_main_menu() {
	output_and_log "${MAGENTA}=== MD5 Update Script - Main Menu ===${NC}"
    output_and_log "Please select an operation:"
    output_and_log ""
    output_and_log "1) Standard path update (Source_Pfad,Ziel_Pfad,New_filenames)"
    output_and_log "   - Changes directory paths and optionally renames files"
    output_and_log "   - Use 'rename' in New_filenames to auto-generate new names"
    output_and_log "   - Empty Ziel_Pfad and New_filenames matched entries will be deleted"
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
    read -r menu_choice
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

# --- MAIN SCRIPT ---

# Welcome message
output_and_log "${BLUE}=== MD5 Checksum Path Update Script v7.2 ===${NC}"
output_and_log "This tool updates file paths in MD5 checksum files without moving actual files."
output_and_log "Performance optimized for large files (1M+ entries)."
output_and_log ""

# Parse command line options
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

# Get working directory
if [ -z "$BASE_PATH" ]; then
    info "No base directory specified."
    echo -ne "Use current directory ($(pwd))? [y/n]: "
    read -r choice
    TERMINAL_LOG+=("Use current directory ($(pwd))? [y/n]: $choice")
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        BASE_PATH=$(pwd)
    else
        echo -ne "Please enter base directory path: "
        read -r BASE_PATH
        TERMINAL_LOG+=("Please enter base directory path: $BASE_PATH")
    fi
fi

BASE_PATH=$(normalize_path "$BASE_PATH")

# Check if directory exists
[ ! -d "$BASE_PATH" ] && error_exit "Base directory '$BASE_PATH' not found."
cd "$BASE_PATH" || error_exit "Cannot change to directory: $BASE_PATH"

info "Working directory: $(pwd)"

# Ask about subdirectory search
echo -ne "Search for files in subdirectories too? [y/n]: "
read -r subdir_choice
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

# Show main menu
show_main_menu
OPERATION=$?

# Handle clean old files operation
if [ "$OPERATION" -eq 4 ]; then
    info "Cleaning old backup and output files..."
    clean_old_files "$BASE_PATH" $SEARCH_DEPTH
    
    output_file="md5_update_paths_output_$(date +%Y%m%d_%H%M%S).log"
    {
        echo "=== Old Files Cleanup Report ==="
        echo "Execution time: $(date)"
        echo "Base directory: $BASE_PATH"
        echo "Search subdirectories: $SEARCH_SUBDIRS"
        echo "Dry-run mode: $DRY_RUN"
        echo
        echo "=== Terminal Output ==="
        printf "%s\n" "${TERMINAL_LOG[@]}"
    } > "$output_file"
    
    success "Cleanup report saved: $output_file"
    success "Cleanup operation completed!"
    exit 0
fi

# Find CSV files
find_csv_files "$BASE_PATH" $SEARCH_DEPTH

if [ ${#CSV_FILES[@]} -eq 0 ]; then
    error_exit "No CSV instruction files found in directory: $BASE_PATH"
fi

output_and_log "Available CSV instruction files:"
for i in "${!CSV_FILES[@]}"; do
    output_and_log "$((i+1))) ${CSV_FILES[$i]}"
done

echo -ne "Please select CSV file (1-${#CSV_FILES[@]}): "
read -r csv_choice
TERMINAL_LOG+=("Please select CSV file (1-${#CSV_FILES[@]}): $csv_choice")

if [[ "$csv_choice" =~ ^[0-9]+$ ]] && [ "$csv_choice" -ge 1 ] && [ "$csv_choice" -le ${#CSV_FILES[@]} ]; then
    CSV_FILE=$(normalize_path "${CSV_FILES[$((csv_choice-1))]}")
    info "Selected CSV file: $CSV_FILE"
	
	# Create backup
    CSV_BACKUP_FILE="${CSV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    if [ "$DRY_RUN" = false ]; then
        cp "$CSV_FILE" "$CSV_BACKUP_FILE"
        success "CSV Backup created: $CSV_BACKUP_FILE"
    fi		
else
    error_exit "Invalid selection: $csv_choice"
fi

# Check CSV file
[ ! -r "$CSV_FILE" ] && error_exit "Cannot read CSV file: $CSV_FILE"

# Handle bulk processing (operation 3)
if [ "$OPERATION" -eq 3 ]; then
    info "Processing ALL MD5 files in directory..."
    process_all_md5_files "$CSV_FILE"
    exit 0
fi

# Find and select MD5 file for single file operations
find_md5_files "$BASE_PATH" $SEARCH_DEPTH

if [ ${#MD5_FILES[@]} -eq 0 ]; then
    error_exit "No MD5 checksum files found in directory: $BASE_PATH"
fi

output_and_log "Available MD5 checksum files:"
for i in "${!MD5_FILES[@]}"; do
    output_and_log "$((i+1))) ${MD5_FILES[$i]}"
done

echo -ne "Please select MD5 file (1-${#MD5_FILES[@]}): "
read -r md5_choice
TERMINAL_LOG+=("Please select MD5 file (1-${#MD5_FILES[@]}): $md5_choice")

if [[ "$md5_choice" =~ ^[0-9]+$ ]] && [ "$md5_choice" -ge 1 ] && [ "$md5_choice" -le ${#MD5_FILES[@]} ]; then
    MD5_FILE=$(normalize_path "${MD5_FILES[$((md5_choice-1))]}")
    info "Selected MD5 file: $MD5_FILE"
else
    error_exit "Invalid selection: $md5_choice"
fi

# Check MD5 file
[ ! -r "$MD5_FILE" ] && error_exit "Cannot read MD5 file: $MD5_FILE"

# Process based on operation type - USING FUNCTIONS
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

if [ "$CSV_PROCESSED" = false ]; then
	log_action "No matching entries found - MD5 file unchanged, because of that $backup_file deleted"
	rm -f "$CSV_BACKUP_FILE"
fi

echo ""
output_and_log "${GREEN}=== Script Execution Completed Successfully! ===${NC}"