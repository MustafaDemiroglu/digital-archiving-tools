#!/usr/bin/env bash
###############################################################################
# Script Name: digitalisate_move_and_rename.sh (Version 2.3)
#
# Description:
#   This script helps archivists move and rename TIFF files safely
#   according to instructions in a CSV file.
#
#   - CSV must have 3 columns:
#       Source_Pfad    Ziel_Pfad    New_filenames
#   - Script operations:
#       1) Move files from Source_Pfad → Ziel_Pfad (no copying)
#       2) Create Ziel_Pfad if it doesn't exist
#       3) Smart numbering to prevent file conflicts
#       4) Rename files according to New_filenames column
#       5) Ask user confirmation before operations
#       6) Show colored output and progress
#       7) Save detailed report
#
# Usage:
#   ./digitalisate_move_and_rename.sh [-n] [-v] [base_path]
#
# Options:
#   -n   Dry-run mode (show actions but don't execute)
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
OUTPUT_FILE="$(basename "$0" .sh)_output_$(date +%Y%m%d_%H%M%S).list"
LOG_ACTIONS=()
TOTAL_FILES=0
PROCESSED_FILES=0

# --- HELPER FUNCTIONS ---

# Save action to log with timestamp
log_action() {
    local action="$1"
    local status="${2:-SUCCESS}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    LOG_ACTIONS+=("[$timestamp] [$status] $action")
    
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}LOG:${NC} $action"
    fi
}

# Show error and exit
error_exit() {
    echo -e "${RED}ERROR:${NC} $1" >&2
    exit 1
}

# Show warning message
warning() {
    echo -e "${YELLOW}WARNING:${NC} $1"
}

# Show success message
success() {
    echo -e "${GREEN}SUCCESS:${NC} $1"
}

# Show info message
info() {
    echo -e "${BLUE}INFO:${NC} $1"
}

# Find the next available number in destination folder
get_next_number() {
    local dst_dir="$1"
    local prefix="$2"
    
    if [ ! -d "$dst_dir" ]; then
        echo "1"
        return
    fi
    
    # Check both old and new format files
    local max_num=0
    
    # Format 1: prefix_nr_folder_0001.tif
    for file in "$dst_dir"/${prefix}_nr_*_[0-9][0-9][0-9][0-9].tif; do
        [ -f "$file" ] || continue
        local num=$(basename "$file" .tif | sed -E 's/.*_([0-9]{4})$/\1/')
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt "$max_num" ]; then
            max_num=$num
        fi
    done
    
    # Format 2: any file ending with numbers
    for file in "$dst_dir"/*.tif; do
        [ -f "$file" ] || continue
        local num=$(basename "$file" .tif | sed -E 's/.*[^0-9]([0-9]+)$/\1/')
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt "$max_num" ]; then
            max_num=$num
        fi
    done
    
    echo $((max_num + 1))
}

# Prevent filename conflicts by adding numbers
resolve_filename_conflict() {
    local target_file="$1"
    local counter=1
    
    if [ ! -f "$target_file" ]; then
        echo "$target_file"
        return
    fi
    
    local dir=$(dirname "$target_file")
    local filename=$(basename "$target_file" .tif)
    
    while [ -f "${dir}/${filename}_${counter}.tif" ]; do
        counter=$((counter + 1))
    done
    
    echo "${dir}/${filename}_${counter}.tif"
}

# Show progress bar
show_progress() {
    local current=$1
    local total=$2
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    
    printf "\r${CYAN}Progress: [%*s%*s] %d%% (%d/%d)${NC}" \
        $filled "" $empty "" $percent $current $total
}

# --- WELCOME MESSAGE ---
echo -e "${BLUE}=== Digitalisate Move & Rename Script v2.0 ===${NC}"
echo "This tool safely moves and renames digitized TIFF files."
echo "Features: Conflict prevention, smart numbering, improved error handling"
echo

# --- READ COMMAND LINE OPTIONS (SHORT & LONG) ---
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
        -h|--hilfe|--help)
            echo -e "${BLUE}Usage:${NC} $0 [-n|--dry-run] [-v|--verbose] [base_path]"
            echo -e "Options:"
            echo -e "  -n, --dry-run   Show actions without executing"
            echo -e "  -v, --verbose   Show detailed output"
            echo -e "  -h, --hilfe     Show this help message"
            exit 0
            ;;
        *)
            # Assume it's the base path
            BASE_PATH="$1"
            shift
            ;;
    esac
done

# --- GET WORKING DIRECTORY ---
if [ -z "$1" ]; then
  info "No base directory specified."
  read -p "Use current directory ($(pwd))? [y/n]: " choice
  if [[ "$choice" =~ ^[Yy]$ ]]; then
    BASE_PATH=$(pwd)
  else
    read -p "Please enter base directory path: " BASE_PATH
  fi
else
  BASE_PATH="$1"
fi

# --- CHECK IF DIRECTORY EXISTS ---
[ ! -d "$BASE_PATH" ] && error_exit "Base directory '$BASE_PATH' not found."
cd "$BASE_PATH" || error_exit "Cannot change to directory: $BASE_PATH"

info "Working directory: $(pwd)"

# --- FIND CSV/TXT FILES ---
readarray -t FILES < <(find . -maxdepth 1 -type f \( -name "*.csv" -o -name "*.list" -o -name "*.txt" \) | sort)

if [ ${#FILES[@]} -eq 0 ]; then
  error_exit "No CSV/list/text files found in this directory: $BASE_PATH"
fi

echo "Available instruction files:"
select FILE in "${FILES[@]}"; do
  if [ -n "$FILE" ]; then
    info "Selected file: $FILE"
    break
  fi
done

# --- CHECK IF FILE CAN BE READ ---
if [ ! -r "$FILE" ]; then
  error_exit "Cannot read file: $FILE"
fi

# Count CSV rows (excluding header)
TOTAL_ROWS=$(($(wc -l < "$FILE") - 1))
info "Number of rows to process: $TOTAL_ROWS"

# --- START PROCESSING FILES ---
echo "=" | tr '=' '-' | head -c 60; echo
info "Starting file processing: $FILE"

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
    
    # Clean up empty values
    SRC=$(echo "$SRC" | xargs)
    DST=$(echo "$DST" | xargs)
    NEWNAME=$(echo "$NEWNAME" | xargs)
    
    [ -z "$SRC" ] && continue
    
    PROCESSED_FILES=$((PROCESSED_FILES + 1))
    show_progress $PROCESSED_FILES $TOTAL_ROWS
    
    echo # New line
    info "Processing [$PROCESSED_FILES/$TOTAL_ROWS]: $SRC → $DST"
    
    # --- CHECK SOURCE FOLDER ---
    if [ ! -d "$SRC" ]; then
      warning "Source folder not found: '$SRC' - Skipping..."
      log_action "SKIPPED: Source folder missing - $SRC" "WARNING"
      continue
    fi
    
    # Check TIFF file count
    TIFF_COUNT=$(find "$SRC" -maxdepth 1 -name "*.tif" -o -name "*.tiff" | wc -l)
    if [ "$TIFF_COUNT" -eq 0 ]; then
      warning "No TIFF files in source folder: $SRC - Skipping..."
      log_action "SKIPPED: No TIFF files - $SRC" "WARNING"
      continue
    fi
    
    info "Found TIFF files: $TIFF_COUNT"
    
    # --- CREATE DESTINATION FOLDER ---
	if [ ! -d "$DST" ]; then
		ACTION="Create destination directory: $DST"
		if [ "$DRY_RUN" = true ]; then
			echo -e "${BLUE}[DRY-RUN]${NC} $ACTION"
		else
			if mkdir -p "$DST"; then
				success "Created: $DST"
				log_action "$ACTION"
			else
				error_exit "Cannot create directory: $DST"
			fi
		fi
	fi
    
    # --- MOVE AND RENAME FILES ---
    if [ -n "$NEWNAME" ] && [ "$NEWNAME" = "rename" ]; then
      # --- SEQUENTIAL RENAME MODE ---
      info "Sequential rename mode"
      
      # Build prefix from last 3 folder levels
      IFS='/' read -ra DST_PARTS <<< "$DST"
      L=${#DST_PARTS[@]}
      
      if [ $L -ge 3 ]; then
        PREFIX="${DST_PARTS[$L-3]}_${DST_PARTS[$L-2]}"
        DST_FOLDER="${DST_PARTS[$L-1]}"
      elif [ $L -ge 2 ]; then
        PREFIX="${DST_PARTS[$L-2]}"
        DST_FOLDER="${DST_PARTS[$L-1]}"
      else
        PREFIX="file"
        DST_FOLDER="${DST_PARTS[0]}"
      fi
      
      info "Prefix: $PREFIX, Folder: $DST_FOLDER"
      
      # Find highest number in destination
      NEXT_NUM=$(get_next_number "$DST" "$PREFIX")
      info "Starting number: $NEXT_NUM"
      
      NUM=0
      for SOURCE_FILE in "$SRC"/*.tif "$SRC"/*.tiff; do
        [ -f "$SOURCE_FILE" ] || continue
        
        PAD=$(printf "%04d" $((NEXT_NUM + NUM)))
        TARGET_FILE="${DST}/${PREFIX}_nr_${DST_FOLDER}_${PAD}.tif"
        
        # Check for conflicts (extra safety)
        TARGET_FILE=$(resolve_filename_conflict "$TARGET_FILE")
        
        ACTION="Move and rename: $(basename "$SOURCE_FILE") → $(basename "$TARGET_FILE")"
        
        if [ "$DRY_RUN" = true ]; then
          echo -e "${BLUE}[DRY-RUN]${NC} $ACTION"
        else
          if mv "$SOURCE_FILE" "$TARGET_FILE"; then
            success "$(basename "$TARGET_FILE")"
            log_action "$ACTION"
          else
            warning "Failed: $ACTION"
            log_action "$ACTION" "FAILED"
          fi
        fi
        
        NUM=$((NUM + 1))
      done
      
    elif [ -n "$NEWNAME" ]; then
      # --- SINGLE FILE RENAME MODE ---
      info "Single file rename mode: $NEWNAME"
      
      for SOURCE_FILE in "$SRC"/*.tif "$SRC"/*.tiff; do
        [ -f "$SOURCE_FILE" ] || continue
        
        TARGET_FILE="${DST}/${NEWNAME}.tif"
        TARGET_FILE=$(resolve_filename_conflict "$TARGET_FILE")
        
        ACTION="Move and rename: $(basename "$SOURCE_FILE") → $(basename "$TARGET_FILE")"
        
        if [ "$DRY_RUN" = true ]; then
          echo -e "${BLUE}[DRY-RUN]${NC} $ACTION"
        else
          if mv "$SOURCE_FILE" "$TARGET_FILE"; then
            success "$(basename "$TARGET_FILE")"
            log_action "$ACTION"
          else
            warning "Failed: $ACTION"
            log_action "$ACTION" "FAILED"
          fi
        fi
      done
      
    else
      # --- SIMPLE MOVE MODE ---
      info "Simple move mode (original names will be kept)"
      
      for SOURCE_FILE in "$SRC"/*.tif "$SRC"/*.tiff; do
        [ -f "$SOURCE_FILE" ] || continue
        
        FILENAME=$(basename "$SOURCE_FILE")
        TARGET_FILE="${DST}/${FILENAME}"
        TARGET_FILE=$(resolve_filename_conflict "$TARGET_FILE")
        
        ACTION="Move: $FILENAME → $(basename "$TARGET_FILE")"
        
        if [ "$DRY_RUN" = true ]; then
          echo -e "${BLUE}[DRY-RUN]${NC} $ACTION"
        else
          if mv "$SOURCE_FILE" "$TARGET_FILE"; then
            success "$(basename "$TARGET_FILE")"
            log_action "$ACTION"
          else
            warning "Failed: $ACTION"
            log_action "$ACTION" "FAILED"
          fi
        fi
      done
    fi
    
    echo # Separator line
    
  done
} < "$FILE"

echo
show_progress $TOTAL_ROWS $TOTAL_ROWS
echo
echo

# --- CLEANUP SOURCE FOLDERS ---
if [ "$DRY_RUN" = false ]; then
  echo -e "${YELLOW}Source folder cleanup${NC}"
  read -p "Delete empty source folders? [y/n]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    {
      read # Skip header
      while IFS= read -r LINE; do
        LINE=$(echo "$LINE" | tr -d '\r')
        [ -z "$LINE" ] && continue
        
        IFS=$',;\t' read -r SRC DST NEWNAME <<< "$LINE"
        SRC=$(echo "$SRC" | xargs)
        
        if [ -d "$SRC" ]; then
          # Check if folder is empty
          if [ -z "$(find "$SRC" -name "*.tif" -o -name "*.tiff")" ]; then
            if rmdir "$SRC" 2>/dev/null; then
              success "Deleted: $SRC"
              log_action "Empty source folder deleted: $SRC"
            else
              warning "Cannot delete (not empty): $SRC"
            fi
          else
            warning "Folder still has TIFF files, not deleted: $SRC"
          fi
        fi
      done
    } < "$FILE"
  fi
fi

# --- SAVE REPORT ---
{
  echo "=== Digitalisate Move & Rename Script Report ==="
  echo "Execution time: $(date)"
  echo "Base directory: $BASE_PATH"
  echo "Instruction file: $FILE"
  echo "Dry-run mode: $DRY_RUN"
  echo "Verbose mode: $VERBOSE"
  echo "Total processed rows: $PROCESSED_FILES"
  echo
  echo "=== Operation Details ==="
  printf "%s\n" "${LOG_ACTIONS[@]}"
} > "$OUTPUT_FILE"

success "Report saved: $OUTPUT_FILE"
success "All operations completed!"

if [ "$DRY_RUN" = true ]; then
  info "This was a dry-run. Remove -n parameter for real changes."
fi