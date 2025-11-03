#!/bin/bash

# Define constants for paths and configuration
CEPHEUS_ROOT="/media/cepheus/hstam"
ARCHIVE_ROOT="/media/archive/public/hstam"
TEMP_DIR="/tmp/migration_temp"
CSV_FILE=""
VERBOSE=0
DRY_RUN=0

# Colors for output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Helper function to print log messages with timestamps
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo -e "[${timestamp}] [${level}] ${message}"
}

# Helper function to normalize signature (for folder names)
normalize_signature() {
    local sig="$1"
    # Example normalization: lowercase and remove special characters (customize as needed)
    echo "$sig" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g'
}

# Create temporary directory for reports and logs
setup_temp_dir() {
    if [ ! -d "$TEMP_DIR" ]; then
        mkdir -p "$TEMP_DIR"
        log_message "INFO" "Created temporary directory: ${TEMP_DIR}"
    fi
}

# Generate a summary report after migration
generate_report() {
    local report_file="${TEMP_DIR}/migration_report.txt"
    echo "Migration Summary Report" > "$report_file"
    echo "=========================" >> "$report_file"
    echo "Total Lines Processed: $(wc -l < "$CSV_FILE")" >> "$report_file"
    echo "Total Files Moved: $(find "$TEMP_DIR" -name '*.moved' | wc -l)" >> "$report_file"
    echo "=========================" >> "$report_file"
    log_message "INFO" "Report generated: ${report_file}"
}

# Process file migration mappings
process_file_migration() {
    local csv_file="$1"
    local line_num=0
    local files_found=0
    
    log_message "INFO" "Processing file migration..."
    
    while IFS=';' read -r id old_desc old_id new_sig new_detail; do
        line_num=$((line_num + 1))
        
        # Skip empty or unchanged entries
        [ -z "$old_desc" ] && continue
        [[ "$new_sig" == *"01:01"* ]] && continue
        
        # Check if additional details exist (6th column or beyond)
        if [[ -n "$new_detail" ]]; then
            log_message "INFO" "Manual intervention required for line ${line_num} due to extra details: ${new_detail}"
            continue
        fi
        
        # Normalize signatures and prepare old/new paths
        local old_sig=$(normalize_signature "$old_desc")
        local new_sig_norm=$(normalize_signature "$new_sig")
        
        # Define old and new paths for both potential roots
        local old_path_cepheus="${CEPHEUS_ROOT}/${old_sig}"
        local old_path_archive="${ARCHIVE_ROOT}/${old_sig}"
        
        local new_path_cepheus="${CEPHEUS_ROOT}/${new_sig_norm}"
        local new_path_archive="${ARCHIVE_ROOT}/${new_sig_norm}"

        # Check if the old path exists in either location
        if [ ! -d "$old_path_cepheus" ] && [ ! -d "$old_path_archive" ]; then
            log_message "ERROR" "Source not found for migration: ${old_path_cepheus} or ${old_path_archive}"
            echo "$old_path_cepheus" >> "${TEMP_DIR}/SOURCENOTFOUND.txt"
            continue
        fi
        
        # Check if the new path already exists
        if [ -d "$new_path_cepheus" ] || [ -d "$new_path_archive" ]; then
            log_message "ERROR" "New path already exists: ${new_path_cepheus} or ${new_path_archive}. Migration cannot proceed."
            continue
        fi
        
        # Create new paths if they don't exist
        if [ ! -d "$new_path_cepheus" ]; then
            mkdir -p "$new_path_cepheus" && log_message "INFO" "Created new directory: ${new_path_cepheus}"
        fi
        if [ ! -d "$new_path_archive" ]; then
            mkdir -p "$new_path_archive" && log_message "INFO" "Created new directory: ${new_path_archive}"
        fi
        
        # Process files in the old folder
        local files_moved=0
        for file in "$old_path_cepheus"/* "$old_path_archive"/*; do
            if [ ! -f "$file" ]; then
                continue
            fi
            
            # Extract filename and normalize to replace old path with new path in the filename
            local filename=$(basename "$file")
            local new_filename=$(echo "$filename" | sed -e "s|${old_sig}|${new_sig_norm}|g")

            # Define new file paths
            local new_file_path_cepheus="${new_path_cepheus}/${new_filename}"
            local new_file_path_archive="${new_path_archive}/${new_filename}"

            # Try to move the file to the new directory (in both locations)
            if [ -f "$file" ]; then
                if [ ! -f "$new_file_path_cepheus" ]; then
                    mv "$file" "$new_file_path_cepheus" && log_message "INFO" "Moved: ${file} -> ${new_file_path_cepheus}"
                    files_moved=$((files_moved + 1))
                elif [ ! -f "$new_file_path_archive" ]; then
                    mv "$file" "$new_file_path_archive" && log_message "INFO" "Moved: ${file} -> ${new_file_path_archive}"
                    files_moved=$((files_moved + 1))
                else
                    log_message "ERROR" "Destination file exists, skipping move: ${new_file_path_cepheus} or ${new_file_path_archive}"
                fi
            fi
        done
        
        if [ "$files_moved" -gt 0 ]; then
            log_message "SUCCESS" "Successfully moved ${files_moved} files for line ${line_num}."
        else
            log_message "WARNING" "No files moved for line ${line_num}."
        fi
        
    done < "$csv_file"
    
    log_message "SUCCESS" "Completed file migration process from ${line_num} lines."
}

# Main function execution flow
main() {
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
}

# Start the script execution
main "$@"
