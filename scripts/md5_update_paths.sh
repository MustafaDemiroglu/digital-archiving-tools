#!/usr/bin/env bash
###############################################################################
# Script Name : md5_update_paths.sh
# Version     : 5.6
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
error_exit() { output_and_log "${RED}ERROR:${NC} $1"; exit 1; }
success() { output_and_log "${GREEN}SUCCESS:${NC} $1"; }
info() { output_and_log "${BLUE}INFO:${NC} $1"; }
warning() { output_and_log "${YELLOW}WARNING:${NC} $1"; }

show_progress() {
    local current=$1
    local total=$2
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    printf "\r${CYAN}Progress: [%*s%*s] %d%% (%d/%d)${NC}" \
        $filled "=" $empty " " $percent $current $total
}

# Extract 4-digit number from filename
extract_number() {
    local filename="$1"
    if [[ "$filename" =~ _([0-9]{4})\.tif$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        echo "0001"
    fi
}

# Build new filename
build_new_filename() {
    local old_path="$1"
    local dst_path="$2"
    local newname="$3"
    local old_filename=$(basename "$old_path")
    local original_number=$(extract_number "$old_filename")

    if [ -n "$newname" ] && [ "$(echo "$newname" | tr '[:upper:]' '[:lower:]')" = "rename" ]; then
        IFS='/' read -ra SEGMENTS <<< "$dst_path"
        local len=${#SEGMENTS[@]}
        if [ $len -ge 3 ]; then
            local first="${SEGMENTS[$((len-3))]}"
            local second="${SEGMENTS[$((len-2))]}"
            local third="${SEGMENTS[$((len-1))]}"
            echo "${first}_${second}_nr_${third}_${original_number}.tif"
        elif [ $len -ge 2 ]; then
            local first="${SEGMENTS[$((len-2))]}"
            local second="${SEGMENTS[$((len-1))]}"
            echo "${first}_nr_${second}_${original_number}.tif"
        else
            local segment="${SEGMENTS[$((len-1))]}"
            echo "${segment}_${original_number}.tif"
        fi
    elif [ -n "$newname" ] && [ "$(echo "$newname" | tr '[:upper:]' '[:lower:]')" != "rename" ]; then
        echo "${newname}.tif"
    else
        echo "$old_filename"
    fi
}

# Process 3-column CSV
process_path_update() {
    local md5_file="$1"
    local csv_file="$2"
    info "Processing 3-column CSV: Source_Pfad,Ziel_Pfad,New_filenames"

    [ ! -f "$md5_file" ] && error_exit "MD5 file not found: $md5_file"
    [ ! -f "$csv_file" ] && error_exit "CSV file not found: $csv_file"

    local md5_content=$(cat "$md5_file")
    TOTAL_ROWS=$(($(wc -l < "$csv_file") - 1))
    info "MD5 entries: $(echo "$md5_content" | wc -l), CSV instructions: $TOTAL_ROWS"

    local backup_file="${md5_file}.backup.$(date +%Y%m%d_%H%M%S)"
    [ "$DRY_RUN" = false ] && cp "$md5_file" "$backup_file"

    local updated_content="$md5_content"
    PROCESSED_CHANGES=0
    TOTAL_CHANGES=0

    { read
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

        local temp_content=""
        while IFS= read -r md5_line; do
            if [[ "$md5_line" =~ ^([a-f0-9]{32})([[:space:]]+\*?)(.+)$ ]]; then
                local hash="${BASH_REMATCH[1]}"
                local file_path="${BASH_REMATCH[3]}"

                if [[ "$file_path" == "$src"* ]]; then
                    local new_filename=$(build_new_filename "$file_path" "$dst" "$newname")
                    local new_path="${dst}/${new_filename}"
                    temp_content+="$hash  $new_path"$'\n'
                    TOTAL_CHANGES=$((TOTAL_CHANGES + 1))
                    [ "$VERBOSE" = true ] && info " Updated: $(basename "$file_path") → $(basename "$new_path")"
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

# Process 2-column CSV
process_simple_rename() {
    local md5_file="$1"
    local csv_file="$2"
    info "Processing 2-column CSV: old_full_path,new_full_path"

    [ ! -f "$md5_file" ] && error_exit "MD5 file not found: $md5_file"
    [ ! -f "$csv_file" ] && error_exit "CSV file not found: $csv_file"

    local md5_content=$(cat "$md5_file")
    TOTAL_ROWS=$(($(wc -l < "$csv_file") - 1))
    info "MD5 entries: $(echo "$md5_content" | wc -l), CSV instructions: $TOTAL_ROWS"

    local backup_file="${md5_file}.backup.$(date +%Y%m%d_%H%M%S)"
    [ "$DRY_RUN" = false ] && cp "$md5_file" "$backup_file"

    local updated_content="$md5_content"
    PROCESSED_CHANGES=0
    TOTAL_CHANGES=0

    { read
      while IFS= read -r line; do
        line=$(echo "$line" | tr -d '\r')
        [ -z "$line" ] && continue
        IFS=',' read -r old_path new_path <<< "$line"
        old_path=$(echo "$old_path" | xargs)
        new_path=$(echo "$new_path" | xargs)
        [ -z "$old_path" ] || [ -z "$new_path" ] && continue

        PROCESSED_CHANGES=$((PROCESSED_CHANGES + 1))
        show_progress $PROCESSED_CHANGES $TOTAL_ROWS

        local temp_content=""
        local found_match=false
        while IFS= read -r md5_line; do
            if [[ "$md5_line" =~ ^([a-f0-9]{32})([[:space:]]+\*?)(.+)$ ]]; then
                local hash="${BASH_REMATCH[1]}"
                local file_path="${BASH_REMATCH[3]}"
                if [ "$file_path" = "$old_path" ]; then
                    temp_content+="$hash  $new_path"$'\n'
                    TOTAL_CHANGES=$((TOTAL_CHANGES + 1))
                    found_match=true
                    [ "$VERBOSE" = true ] && info " Match found and updated"
                else
                    temp_content+="$md5_line"$'\n'
                fi
            else
                temp_content+="$md5_line"$'\n'
            fi
        done <<< "$updated_content"
        updated_content="$temp_content"
        [ "$found_match" = false ] && [ "$VERBOSE" = true ] && warning " No match found for: $old_path"
      done
    } < "$csv_file"

    save_results "$md5_file" "$backup_file" "$updated_content"
}

# Save results
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
            printf "%s\n" "$updated_content" > "$md5_file"
            success "Updated MD5 file with $TOTAL_CHANGES changes"
            success "Backup saved: $backup_file"
        fi
    else
        warning "No matching entries found - no changes made"
    fi

    { echo "=== MD5 Update Report ==="
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

# === MAIN EXECUTION ===
info "MD5 Checksum Path Update Script"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=true; info "Dry-run mode enabled"; shift ;;
        -v|--verbose) VERBOSE=true; info "Verbose mode enabled"; shift ;;
        -h|--help) echo "Usage: $0 [-n|--dry-run] [-v|--verbose] [base_path]"; exit 0 ;;
        *) BASE_PATH="$1"; shift ;;
    esac
done

[ -z "$BASE_PATH" ] && BASE_PATH=$(pwd)
[ ! -d "$BASE_PATH" ] && error_exit "Directory not found: $BASE_PATH"
cd "$BASE_PATH" || error_exit "Cannot change to: $BASE_PATH"
info "Working in: $(pwd)"

OUTPUT_FILE="md5_update_output_$(date +%Y%m%d_%H%M%S).log"

output_and_log "${BLUE}=== MD5 Path Update Script v5.1 (Fixed) ===${NC}"
output_and_log "Select operation:"
output_and_log "1) Path update with rename (3-column CSV)"
output_and_log "2) Simple path/filename change (2-column CSV)"
output_and_log "3) Exit"
echo -ne "Choice (1-3): "
read choice

case "$choice" in
    1) find . -maxdepth 1 -type f -name "*.csv"; echo -ne "CSV file: "; read CSV_FILE; echo -ne "MD5 file: "; read MD5_FILE; process_path_update "$MD5_FILE" "$CSV_FILE" ;;
    2) find . -maxdepth 1 -type f -name "*.csv"; echo -ne "CSV file: "; read CSV_FILE; echo -ne "MD5 file: "; read MD5_FILE; process_simple_rename "$MD5_FILE" "$CSV_FILE" ;;
    3) info "Goodbye!"; exit 0 ;;
    *) error_exit "Invalid choice: $choice" ;;
esac

success "Operation completed successfully!"
[ "$DRY_RUN" = true ] && info "This was a dry-run. Remove -n to make actual changes."
