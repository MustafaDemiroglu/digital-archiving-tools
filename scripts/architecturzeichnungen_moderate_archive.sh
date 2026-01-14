#!/bin/bash

################################################################################
# Change Archive Struktur (Move/Copy and Rename) Script
# 
# !!!!!!!!! VERY IMPORTANT : TESTING IS NOT DONE YET. USE OTHER SCRIPT !!!!!!!!!
# ------------------ hstam_architekturzeichnungen_restructure ------------------ 
#
# Script Name: architecturzeichnungen_moderate_archive.sh 
# Version:1.1
# Author: Mustafa Demiroglu
# Organisation: HlaDigiTeam
# License: MIT
#
# PURPOSE:
#   This script processes architectural drawing archive data from a CSV file
#   and prepares file migration from old folder structures to new ones.
#
# HOW IT WORKS:
#   1. Reads a CSV file with old and new archive signatures
#   2. Creates new folder structure based on normalized signatures
#   3. Finds files in old locations and prepares move list
#   4. Generates logs for missing sources/destinations
#
# CSV FORMAT EXPECTED (semicolon-separated):
#   id_1;description;id_2;Signature;New_Signature;Additional_Details
#   Example:
#   20940155;Bad Brückenau, Projekte...;9395764;Karten P II 10162;Karten P II 10162/3
#
# USAGE:
#   ./architecturzeichnungen_moderate_archive.sh input.csv
#   ./architecturzeichnungen_moderate_archive.sh -v input.csv          # Verbose mode
#   ./architecturzeichnungen_moderate_archive.sh -n input.csv          # Dry-run (no actual changes)
#   ./architecturzeichnungen_moderate_archive.sh -h                    # Show help
#
# OUTPUT:
#   - dirs_to_create.log: List of directories to be created
#   - moving_list.txt: List of files to move (source;destination)
#   - SOURCENOTFOUND.txt: Old folders that don't exist
#   - DESTNOTFOUND.txt: Files with no matching new destination
#   - migration.log: Detailed operation log
#
################################################################################

set -o pipefail

# Configuration
ARCHIVE_ROOT="/media/archive/public/www/hstam"
CEPHEUS_ROOT="/media/cepheus/hstam"
TEMP_DIR="/tmp/archzeich"
VERBOSE=0
DRY_RUN=0

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

################################################################################
# Functions
################################################################################

# Print help message
show_help() {
    cat << EOF
Change Archive Architectur Script
USAGE:
    $0 [OPTIONS] CSV_FILE

OPTIONS:
    -h, --help          Show this help message
    -v, --verbose       Enable verbose output
    -n, --dry-run       Simulate operations without making changes
    
ARGUMENTS:
    CSV_FILE            Input CSV file with archive data (required)

EXAMPLES:
    $0 archive_data.csv
    $0 --verbose --dry-run archive_data.csv
    $0 -v -n archive_data.csv

EOF
    exit 0
}

# Logging function
log_message() {
    local level=$1
    shift
    local message="$@"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[${timestamp}] [${level}] ${message}" >> "${TEMP_DIR}/migration.log"
    
    if [ "$VERBOSE" -eq 1 ] || [ "$level" = "ERROR" ]; then
        case $level in
            ERROR)   echo -e "${RED}[ERROR]${NC} ${message}" >&2 ;;
            WARNING) echo -e "${YELLOW}[WARNING]${NC} ${message}" ;;
            INFO)    echo -e "${BLUE}[INFO]${NC} ${message}" ;;
            SUCCESS) echo -e "${GREEN}[SUCCESS]${NC} ${message}" ;;
        esac
    fi
}

# Normalize signature to folder path
# Example: "Karten P II 10162/3" -> "karten_p_ii_10162--3"
normalize_signature() {
    local signature="$1"
    
    echo "$signature" | sed \
        -e 's/ /_/g' \
        -e 's/_$//' \
        -e 's/.*/\L&/' \
        -e 's/_\([abcpr]_[1-9i]\)/\/\1/g' \
        -e 's/\([0-9]\)\/\([0-9]\)/\1--\2/g'
}

# Extract old signature from description
# This extracts the meaningful part from column 4 (old path)
extract_old_signature() {
    local description="$1"
    
    # Extract pattern before comma, remove special chars, lowercase
    echo "$description" | sed \
        -e 's/,.*$//' \
        -e 's/ /_/g' \
        -e 's/.*/\L&/' \
        -e 's/_\([abcpr]_[1-9i]\)/\/\1/g'
}

# Extract page signature from filename
# Example: "hstam_karten_nr_123_4_5.jpg" -> "123_4_5"
extract_page_from_filename() {
    local filename="$1"
    
    echo "$filename" | sed \
        -e 's/\.jpe\?g$//' \
        -e 's/.*_nr_\(.*\)/\1/' \
        -e 's/_0*\([1-9]\)/_\1/g' \
        -e 's/\([0-9]\)_\([1-9]\)/\1--\2/' \
        -e 's/_\([rv]\)$/\1/'
}

# Setup temporary directory
setup_temp_dir() {
    if [ ! -d "$TEMP_DIR" ]; then
        mkdir -p "$TEMP_DIR" || {
            echo -e "${RED}ERROR: Cannot create temp directory ${TEMP_DIR}${NC}" >&2
            exit 1
        }
    fi
    
    # Initialize log files
    : > "${TEMP_DIR}/migration.log"
    : > "${TEMP_DIR}/SOURCENOTFOUND.txt"
    : > "${TEMP_DIR}/DESTNOTFOUND.txt"
    : > "${TEMP_DIR}/dirs_to_create.log"
    : > "${TEMP_DIR}/moving_list.txt"
    
    log_message "INFO" "Temporary directory initialized: ${TEMP_DIR}"
}

#   Architecturzeichnug;Description;Id;Old_Signature;New_Signature;Additional_Details

# Parse CSV and create folder structure list
process_csv_for_folders() {
    local csv_file="$1"
    local line_num=0
    local processed=0
    
    log_message "INFO" "Processing CSV for folder creation..."
    
    # Read CSV line by line
    while IFS=';' read -r arch_sig desc id signatur new_sig extra_info1 extra_info2 extra_info3; do
        line_num=$((line_num + 1))
        
        # Skip empty lines
        [ -z "$signatur" ] && continue
        
        # Skip lines with "01:01" marker (no change needed)
        if [[ "$signatur" == *"01:01"* ]]; then
            log_message "INFO" "Skipping unchanged entry at line ${line_num}"
            continue
        fi
		
		# Skip rows with no new signature or with extra details in columns 6 or later
        if [ -z "$new_sig" ] || [ -n "$extra_info1" ] || [ -n "$extra_info2" ] || [ -n "$extra_info3" ]; then
            log_message "INFO" "Skipping row at line ${line_num} due to extra info or missing new signature"
            continue
        fi
        
		# Normalize signatures
        local normalized_old_sig=$(normalize_signature "$signatur")
        local normalized_new_sig=$(normalize_signature "$new_sig")
        
        # Check if old paths exist
        local old_path_ceph="${CEPHEUS_ROOT}/${normalized_old_sig}"
        local old_path_arch="${ARCHIVE_ROOT}/${normalized_old_sig}"
        
        if [ ! -d "$old_path_ceph" ] && [ ! -d "$old_path_arch" ]; then
            log_message "ERROR" "Source not found for line ${line_num}: ${old_path_ceph} or ${old_path_arch}"
            echo "$old_path_ceph" >> "${TEMP_DIR}/SOURCENOTFOUND.txt"
            continue
        fi
        
        # Normalize and create folder path
        echo "${ARCHIVE_ROOT}/${normalized_new_sig}" >> "${TEMP_DIR}/dirs_to_create.log"
		echo "${CEPHEUS_ROOT}/${normalized_new_sig}" >> "${TEMP_DIR}/dirs_to_create.log"
        
        processed=$((processed + 1))
        
    done < "$csv_file"
    
    log_message "SUCCESS" "Processed ${processed} entries for folder creation from ${line_num} lines"
}

# Create directories
create_directories() {
    if [ "$DRY_RUN" -eq 1 ]; then
        log_message "INFO" "DRY-RUN: Would create $(wc -l < ${TEMP_DIR}/dirs_to_create.log) directories"
        [ "$VERBOSE" -eq 1 ] && cat "${TEMP_DIR}/dirs_to_create.log"
        return
    fi
    
    log_message "INFO" "Creating directory structure..."
    
    local created=0
    local skipped=0
    
    while read -r dir; do
        if [ -d "$dir" ]; then
            skipped=$((skipped + 1))
            log_message "INFO" "Directory already exists: ${dir}"
        else
            if mkdir -p "$dir" 2>/dev/null; then
                created=$((created + 1))
                log_message "INFO" "Created directory: ${dir}"
            else
                log_message "ERROR" "Failed to create directory: ${dir}"
            fi
        fi
    done < "${TEMP_DIR}/dirs_to_create.log"
    
    log_message "SUCCESS" "Created ${created} new directories, ${skipped} already existed"
}

# Process file migration list
process_file_migration() {
    local csv_file="$1"
    local line_num=0
    local files_found=0
    
    log_message "INFO" "Processing file migration..."
    
    while IFS=';' read -r arch_sig desc id signatur new_sig extra_info1 extra_info2 extra_info3; do
        line_num=$((line_num + 1))
        
        # Skip empty or unchanged entries
        [ -z "$signatur" ] && continue
        [[ "$signatur" == *"01:01"* ]] && continue
        
        # Extract old folder path from description
        local old_sig=$(extract_old_signature "$signatur")
        local old_path="${ARCHIVE_ROOT}/${old_sig}"
        
        # Check if old directory exists
        if [ ! -d "$old_path" ]; then
            echo "$old_path" >> "${TEMP_DIR}/SOURCENOTFOUND.txt"
            log_message "WARNING" "Source not found: ${old_path}"
            continue
        fi
        
        # Process files in old directory
        cd "$old_path" || continue
        
        for file in *; do
            # Skip if not a regular file
            [ ! -f "$file" ] && continue
            
            files_found=$((files_found + 1))
            
            # Extract page signature from filename
            local page_sig=$(extract_page_from_filename "$file")
            local sheet_sig=$(echo "$page_sig" | sed 's/[rv]$//')
            
            # Build new paths
            local new_base_sig="${new_sig:-$signatur}"
            local new_page=$(normalize_signature "${new_base_sig}/${page_sig}")
            local new_sheet=$(normalize_signature "${new_base_sig}/${sheet_sig}")
            
            local source_full="${old_path}/${file}"
            local dest_page="${ARCHIVE_ROOT}/${new_page}"
            local dest_sheet="${ARCHIVE_ROOT}/${new_sheet}"
            
            # Check which destination exists
            if [ -d "$dest_page" ]; then
                echo "${source_full};${dest_page}" >> "${TEMP_DIR}/moving_list.txt"
                log_message "INFO" "Mapped: ${file} -> ${dest_page}"
            elif [ -d "$dest_sheet" ]; then
                echo "${source_full};${dest_sheet}" >> "${TEMP_DIR}/moving_list.txt"
                log_message "INFO" "Mapped: ${file} -> ${dest_sheet}"
            else
                echo "${source_full}" >> "${TEMP_DIR}/DESTNOTFOUND.txt"
                log_message "WARNING" "No destination found for: ${source_full}"
            fi
        done
    done < "$csv_file"
    
    log_message "SUCCESS" "Processed ${files_found} files from ${line_num} CSV entries"
}

# Execute file moves
execute_moves() {
    if [ ! -f "${TEMP_DIR}/moving_list.txt" ] || [ ! -s "${TEMP_DIR}/moving_list.txt" ]; then
        log_message "WARNING" "No files to move"
        return
    fi
    
    local total=$(wc -l < "${TEMP_DIR}/moving_list.txt")
    
    if [ "$DRY_RUN" -eq 1 ]; then
        log_message "INFO" "DRY-RUN: Would move ${total} files"
        [ "$VERBOSE" -eq 1 ] && cat "${TEMP_DIR}/moving_list.txt"
        return
    fi
    
    log_message "INFO" "Moving ${total} files..."
    
    local moved=0
    local failed=0
    
    while IFS=';' read -r source dest; do
        if [ -f "$source" ] && [ -d "$dest" ]; then
            if mv "$source" "$dest/" 2>/dev/null; then
                moved=$((moved + 1))
                log_message "INFO" "Moved: ${source} -> ${dest}/"
            else
                failed=$((failed + 1))
                log_message "ERROR" "Failed to move: ${source} -> ${dest}/"
            fi
        else
            failed=$((failed + 1))
            log_message "ERROR" "Invalid source or destination: ${source} -> ${dest}"
        fi
    done < "${TEMP_DIR}/moving_list.txt"
    
    log_message "SUCCESS" "Moved ${moved} files successfully, ${failed} failed"
}

# Generate summary report
generate_report() {
    echo ""
    echo "======================================================================"
    echo "                    MIGRATION SUMMARY REPORT"
    echo "======================================================================"
    echo ""
    
    if [ -f "${TEMP_DIR}/dirs_to_create.log" ]; then
        local dir_count=$(wc -l < "${TEMP_DIR}/dirs_to_create.log")
        echo "Directories to create: ${dir_count}"
    fi
    
    if [ -f "${TEMP_DIR}/moving_list.txt" ]; then
        local move_count=$(wc -l < "${TEMP_DIR}/moving_list.txt")
        echo "Files to move: ${move_count}"
    fi
    
    if [ -f "${TEMP_DIR}/SOURCENOTFOUND.txt" ] && [ -s "${TEMP_DIR}/SOURCENOTFOUND.txt" ]; then
        local source_missing=$(wc -l < "${TEMP_DIR}/SOURCENOTFOUND.txt")
        echo -e "${YELLOW}Sources not found: ${source_missing}${NC}"
    fi
    
    if [ -f "${TEMP_DIR}/DESTNOTFOUND.txt" ] && [ -s "${TEMP_DIR}/DESTNOTFOUND.txt" ]; then
        local dest_missing=$(wc -l < "${TEMP_DIR}/DESTNOTFOUND.txt")
        echo -e "${YELLOW}Destinations not found: ${dest_missing}${NC}"
    fi
    
    echo ""
    echo "Output files located in: ${TEMP_DIR}"
    echo "  - dirs_to_create.log"
    echo "  - moving_list.txt"
    echo "  - SOURCENOTFOUND.txt"
    echo "  - DESTNOTFOUND.txt"
    echo "  - migration.log"
    echo ""
    echo "======================================================================"
}

################################################################################
# Main Script
################################################################################

# Parse command line arguments
CSV_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -*)
            echo -e "${RED}ERROR: Unknown option: $1${NC}" >&2
            echo "Use -h or --help for usage information"
            exit 1
            ;;
        *)
            CSV_FILE="$1"
            shift
            ;;
    esac
done

# Validate CSV file argument
if [ -z "$CSV_FILE" ]; then
    echo -e "${RED}ERROR: CSV file argument is required${NC}" >&2
    echo "Use -h or --help for usage information"
    exit 1
fi

if [ ! -f "$CSV_FILE" ]; then
    echo -e "${RED}ERROR: CSV file not found: ${CSV_FILE}${NC}" >&2
    exit 1
fi

# Display mode information
echo "======================================================================"
echo "                Archive Migration Script Starting"
echo "======================================================================"
echo "CSV File: ${CSV_FILE}"
echo "Archive Root: ${ARCHIVE_ROOT}"
echo "Temp Directory: ${TEMP_DIR}"
[ "$VERBOSE" -eq 1 ] && echo "Mode: VERBOSE"
[ "$DRY_RUN" -eq 1 ] && echo -e "Mode: ${YELLOW}DRY-RUN (simulation only)${NC}"
echo "======================================================================"
echo ""

# Execute migration process
setup_temp_dir

log_message "INFO" "Starting migration process"
log_message "INFO" "CSV file: ${CSV_FILE}"

# Step 1: Process CSV and create folder list
process_csv_for_folders "$CSV_FILE"

# Step 2: Create directories
create_directories

# Step 3: Process file migration mappings
process_file_migration "$CSV_FILE"

# Step 4: Execute moves (if not dry-run)
# Uncomment the line below when ready to actually move files
# execute_moves

log_message "INFO" "Migration process completed"

# Generate summary report
generate_report

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    echo -e "${YELLOW}DRY-RUN completed. No actual changes were made.${NC}"
else
    echo -e "${GREEN}Process completed. Review logs in ${TEMP_DIR}${NC}"
    echo -e "${YELLOW}NOTE: File moving is commented out for safety.${NC}"
    echo -e "${YELLOW}Uncomment 'execute_moves' in script to enable actual file moving.${NC}"
fi
echo ""

exit 0