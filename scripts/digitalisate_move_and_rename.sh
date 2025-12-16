#!/usr/bin/env bash
###############################################################################
# Script Name: digitalisate_move_and_rename.sh
# Version: 3.2 
# Author: Mustafa Demiroglu
# Organisation: HlaDigiTeam
#
# Description:
#   This script helps archivists move and rename media files safely
#   according to instructions in a CSV file.
#
#   Supported file types (case-insensitive):
#       jpg, jpeg, tif, tiff, pdf, mp4, mkv, wav, mp3
#
#   - CSV must have 3 columns:
#       Source_Pfad    Ziel_Pfad    New_filenames
#   - Script operations:
#       1) Move files from Source_Pfad → Ziel_Pfad (not only copying)
#       2) Create Ziel_Pfad if it doesn't exist
#       3) Smart numbering to prevent file conflicts
#       4) Rename files according to New_filenames column
#       5) Ask user confirmation before operations
#       6) Show colored output and progress
#       7) Save detailed report with all terminal output
#       8) Create CSV list of all renamed files
#
# Usage:
#   ./digitalisate_move_and_rename.sh [-n] [-v] [base_path]
#   ./digitalisate_move_and_rename.sh [-n] [-v]
#   ./digitalisate_move_and_rename.sh [-n]
#   ./digitalisate_move_and_rename.sh [-v]
#   ./digitalisate_move_and_rename.sh [base_path]
#   ./digitalisate_move_and_rename.sh
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
OUTPUT_FILE="move_and_rename_$(date +%Y%m%d_%H%M%S).log"
RENAMED_CSV="renamed_files_$(date +%Y%m%d_%H%M%S).csv"
LOG_ACTIONS=()
TERMINAL_LOG=()
RENAMED_FILES=()
TOTAL_FILES=0
PROCESSED_FILES=0

# --- FILETYPE SETTINGS ---
SUPPORTED_REGEX='.*\.\(jpe?g|tiff?|pdf|mp4|mkv|wav|mp3\)$'  # case-insensitive with -iregex
SUPPORTED_LIST='jpg, jpeg, tif, tiff, pdf, mp4, mkv, wav, mp3'

# Safer globs: expand to empty when no match
shopt -s nullglob

# --- HELPER FUNCTIONS ---

# Function to capture and display output
output_and_log() {
    local message="$1"
    echo -e "$message"
    # Store plain text version for log (remove color codes)
    local plain_message
    plain_message=$(echo -e "$message" | sed 's/\x1B\[[0-9;]*[JKmsu]//g')
    TERMINAL_LOG+=("$plain_message")
}

# Save action to log with timestamp
log_action() {
    local action="$1"
    local status="${2:-SUCCESS}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    LOG_ACTIONS+=("[$timestamp] [$status] $action")
    TERMINAL_LOG+=("[$timestamp] [$status] $action")
}

# Add file rename entry to CSV tracking
log_file_rename() {
    local old_path="$1"
    local new_path="$2"
    local old_rel
    local new_rel
    old_rel=$(get_relative_path "$old_path")
    new_rel=$(get_relative_path "$new_path")
    RENAMED_FILES+=("$old_rel,$new_rel")
}

# Get relative path with 2 parent levels + filename
get_relative_path() {
    local full_path="$1"
    local rel_path
    rel_path=$(realpath --relative-to="$BASE_PATH" "$full_path" 2>/dev/null || echo "$full_path")
    IFS='/' read -ra PATH_PARTS <<< "$rel_path"
    local num_parts=${#PATH_PARTS[@]}
    if [ $num_parts -le 3 ]; then
        echo "$rel_path"
    else
        echo "${PATH_PARTS[$((num_parts-3))]}/${PATH_PARTS[$((num_parts-2))]}/${PATH_PARTS[$((num_parts-1))]}"
    fi
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

# Extract file extension (lowercase, without dot)
get_ext_lc() {
    local f="$1"
    local ext="${f##*.}"
    printf '%s' "$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
}

# Insert counter before extension if target exists (generic)
# input: full target path (with extension)
resolve_filename_conflict() {
    local target_file="$1"
    local dir base name ext
    dir=$(dirname "$target_file")
    base=$(basename "$target_file")
    name="${base%.*}"
    ext="${base##*.}"

    local counter=1
    local candidate="$target_file"
    while [ -f "$candidate" ]; do
        candidate="${dir}/${name}_${counter}.${ext}"
        counter=$((counter + 1))
    done
    echo "$candidate"
}

# Find the next available number in destination folder (generic, across extensions)
get_next_number() {
    local dst_dir="$1"
    local prefix="$2"
    local max_num=0

    [ ! -d "$dst_dir" ] && { echo "1"; return; }

    # Format 1: prefix_nr_folder_0001.<ext>
    # We scan all supported extensions case-insensitively and parse last 4 digits.
    while IFS= read -r -d '' file; do
        local base num
        base=$(basename "$file")
        base="${base%.*}"                                # strip extension
        num=$(echo "$base" | sed -E 's/.*_([0-9]{4})$/\1/')
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt "$max_num" ]; then
            max_num=$num
        fi
	done < <(find "$dst_dir" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.tif" -o -iname "*.tiff" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.wav" -o -iname "*.mp3" \) -print0 2>/dev/null)

    # Format 2: any basename ending with digits before extension
    while IFS= read -r -d '' file; do
        local base num
        base=$(basename "$file")
        base="${base%.*}"
        num=$(echo "$base" | sed -E 's/.*[^0-9]([0-9]+)$/\1/')
        if [[ "$num" =~ ^[0-9]+$ ]] && [ "$num" -gt "$max_num" ]; then
            max_num=$num
        fi
	done < <(find "$dst_dir" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.tif" -o -iname "*.tiff" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.wav" -o -iname "*.mp3" \) -print0 2>/dev/null)

    echo $((max_num + 1))
}

# Show progress bar
show_progress() {
    local current=$1
    local total=$2
    local percent=$((current * 100 / (total==0?1:total)))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    local progress_msg
    progress_msg=$(printf "\r${CYAN}Progress: [%*s%*s] %d%% (%d/%d)${NC}" \
        $filled "" $empty "" $percent $current $total)
    echo -ne "$progress_msg"
    local plain_progress
    plain_progress=$(printf "Progress: [%*s%*s] %d%% (%d/%d)" \
        $filled "=" $empty " " $percent $current $total)
    TERMINAL_LOG+=("$plain_progress")
}

# --- WELCOME MESSAGE ---
output_and_log "${BLUE}=== Digitalisate Move & Rename Script v3.1 ===${NC}"
output_and_log "This tool safely moves and renames media files."
output_and_log "Supported types: ${SUPPORTED_LIST}"
output_and_log "Features: Conflict prevention, smart numbering, improved error handling"
output_and_log "Complete terminal logging and file rename tracking"
output_and_log ""

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
            output_and_log "${BLUE}Usage:${NC} $0 [-n|--dry-run] [-v|--verbose] [base_path]"
            output_and_log "Options:"
            output_and_log "  -n, --dry-run   Show actions without executing"
            output_and_log "  -v, --verbose   Show detailed output"
            output_and_log "  -h, --hilfe     Show this help message"
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

# --- FIND CSV/TXT FILES ---
readarray -t FILES < <(find . -maxdepth 1 -type f \( -name "*.csv" -o -name "*.list" -o -name "*.txt" \) | sort)

if [ ${#FILES[@]} -eq 0 ]; then
  error_exit "No CSV/list/text files found in this directory: $BASE_PATH"
fi

output_and_log "Available instruction files:"
for i in "${!FILES[@]}"; do
    output_and_log "$((i+1))) ${FILES[$i]}"
done

echo -ne "Please select a file (1-${#FILES[@]}): "
read file_choice
TERMINAL_LOG+=("Please select a file (1-${#FILES[@]}): $file_choice")

if [[ "$file_choice" =~ ^[0-9]+$ ]] && [ "$file_choice" -ge 1 ] && [ "$file_choice" -le ${#FILES[@]} ]; then
    FILE="${FILES[$((file_choice-1))]}"
    info "Selected file: $FILE"
else
    error_exit "Invalid selection: $file_choice"
fi

# --- CHECK IF FILE CAN BE READ ---
if [ ! -r "$FILE" ]; then
  error_exit "Cannot read file: $FILE"
fi

# Count CSV rows (excluding header)
TOTAL_ROWS=$(($(wc -l < "$FILE") - 1))
info "Number of rows to process: $TOTAL_ROWS"

# Initialize renamed files CSV
{
    if [ "$DRY_RUN" = true ]; then
        echo "# DRY-RUN MODE: The following changes were not actually made."
        echo "# This list shows what would happen if you run the script in real mode."
        echo "#"
    fi
    echo "old_pfad_and_name,new_pfad_and_name"
} > "$RENAMED_CSV"

# --- START PROCESSING FILES ---
output_and_log "$(echo "=" | tr '=' '-' | head -c 60)"
info "Starting file processing: $FILE"

{
  # Skip CSV header
  read
  while IFS= read -r LINE; do
    LINE=$(echo "$LINE" | tr -d '\r')
    [ -z "$LINE" ] && continue

    # Parse CSV - supports comma, semicolon, tab
    IFS=$',;\t' read -r SRC DST NEWNAME <<< "$LINE"

    SRC=$(echo "$SRC" | xargs)
    DST=$(echo "$DST" | xargs)
    NEWNAME=$(echo "$NEWNAME" | xargs)

    [ -z "$SRC" ] && continue

    PROCESSED_FILES=$((PROCESSED_FILES + 1))
    show_progress $PROCESSED_FILES $TOTAL_ROWS

    output_and_log "" # New line
    info "Processing [$PROCESSED_FILES/$TOTAL_ROWS]: $SRC → $DST"

    # --- CHECK SOURCE FOLDER ---
    if [ ! -d "$SRC" ]; then
      warning "Source folder not found: '$SRC' - Skipping..."
      log_action "SKIPPED: Source folder missing - $SRC" "WARNING"
      continue
    fi

    # Check supported file count
    FILE_COUNT=$(find "$SRC" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.tif" -o -iname "*.tiff" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.wav" -o -iname "*.mp3" \) | wc -l)
	if [ "$FILE_COUNT" -eq 0 ]; then
      warning "No supported media files in source folder: $SRC - Skipping..."
      log_action "SKIPPED: No supported files - $SRC" "WARNING"
      continue
    fi

    info "Found supported files: $FILE_COUNT"

    # --- CREATE DESTINATION FOLDER ---
    if [ ! -d "$DST" ]; then
        ACTION="Create destination directory: $DST"
        if [ "$DRY_RUN" = true ]; then
            output_and_log "${BLUE}[DRY-RUN]${NC} $ACTION"
        else
            if mkdir -p "$DST"; then
                success "Created: $DST"
                log_action "$ACTION"
            else
                error_exit "Cannot create directory: $DST"
            fi
        fi
    fi

    # Collect source files (sorted), case-insensitive by regex
    mapfile -t SOURCE_FILES < <(find "$SRC" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.tif" -o -iname "*.tiff" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.wav" -o -iname "*.mp3" \) | sort)

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
      for SOURCE_FILE in "${SOURCE_FILES[@]}"; do
        [ -f "$SOURCE_FILE" ] || continue

        PAD=$(printf "%04d" $((NEXT_NUM + NUM)))
        ext="$(get_ext_lc "$SOURCE_FILE")"
        TARGET_FILE="${DST}/${PREFIX}_nr_${DST_FOLDER}_${PAD}.${ext}"

        # Check for conflicts (extra safety)
        TARGET_FILE=$(resolve_filename_conflict "$TARGET_FILE")

        ACTION="Move and rename: $(basename "$SOURCE_FILE") → $(basename "$TARGET_FILE")"

        if [ "$DRY_RUN" = true ]; then
          output_and_log "${BLUE}[DRY-RUN]${NC} $ACTION"
          log_file_rename "$SOURCE_FILE" "$TARGET_FILE"
        else
          if mv "$SOURCE_FILE" "$TARGET_FILE"; then
            success "$(basename "$TARGET_FILE")"
            log_action "$ACTION"
            log_file_rename "$SOURCE_FILE" "$TARGET_FILE"
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

      for SOURCE_FILE in "${SOURCE_FILES[@]}"; do
        [ -f "$SOURCE_FILE" ] || continue

        ext="$(get_ext_lc "$SOURCE_FILE")"
        TARGET_FILE="${DST}/${NEWNAME}.${ext}"
        TARGET_FILE=$(resolve_filename_conflict "$TARGET_FILE")

        ACTION="Move and rename: $(basename "$SOURCE_FILE") → $(basename "$TARGET_FILE")"

        if [ "$DRY_RUN" = true ]; then
          output_and_log "${BLUE}[DRY-RUN]${NC} $ACTION"
          log_file_rename "$SOURCE_FILE" "$TARGET_FILE"
        else
          if mv "$SOURCE_FILE" "$TARGET_FILE"; then
            success "$(basename "$TARGET_FILE")"
            log_action "$ACTION"
            log_file_rename "$SOURCE_FILE" "$TARGET_FILE"
          else
            warning "Failed: $ACTION"
            log_action "$ACTION" "FAILED"
          fi
        fi
      done

    else
      # --- SIMPLE MOVE MODE ---
      info "Simple move mode (original names and extensions will be kept)"

      for SOURCE_FILE in "${SOURCE_FILES[@]}"; do
        [ -f "$SOURCE_FILE" ] || continue

        FILENAME=$(basename "$SOURCE_FILE")
        TARGET_FILE="${DST}/${FILENAME}"
        TARGET_FILE=$(resolve_filename_conflict "$TARGET_FILE")

        ACTION="Move: $FILENAME → $(basename "$TARGET_FILE")"

        if [ "$DRY_RUN" = true ]; then
          output_and_log "${BLUE}[DRY-RUN]${NC} $ACTION"
          log_file_rename "$SOURCE_FILE" "$TARGET_FILE"
        else
          if mv "$SOURCE_FILE" "$TARGET_FILE"; then
            success "$(basename "$TARGET_FILE")"
            log_action "$ACTION"
            log_file_rename "$SOURCE_FILE" "$TARGET_FILE"
          else
            warning "Failed: $ACTION"
            log_action "$ACTION" "FAILED"
          fi
        fi
      done
    fi

    output_and_log "" # Separator line

  done
} < "$FILE"

output_and_log ""
show_progress $TOTAL_ROWS $TOTAL_ROWS
output_and_log ""
output_and_log ""

# --- CLEANUP SOURCE FOLDERS ---
if [ "$DRY_RUN" = false ]; then
  output_and_log "${YELLOW}Source folder cleanup${NC}"
  echo -ne "Delete empty source folders? [y/n]: "
  read yn
  TERMINAL_LOG+=("Delete empty source folders? [y/n]: $yn")
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    {
      read # Skip header
      while IFS= read -r LINE; do
        LINE=$(echo "$LINE" | tr -d '\r')
        [ -z "$LINE" ] && continue

        IFS=$',;\t' read -r SRC DST NEWNAME <<< "$LINE"
        SRC=$(echo "$SRC" | xargs)

        if [ -d "$SRC" ]; then
          # Check if folder is empty of supported types
		  if [ -z "$(find "$SRC" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.tif" -o -iname "*.tiff" -o -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.wav" -o -iname "*.mp3" \))" ]; then
            if rmdir "$SRC" 2>/dev/null; then
              success "Deleted: $SRC"
              log_action "Empty source folder deleted: $SRC"
            else
              warning "Cannot delete (not empty): $SRC"
            fi
          else
            warning "Folder still has supported files, not deleted: $SRC"
          fi
        fi
      done
    } < "$FILE"
  fi
fi

# --- SAVE RENAMED FILES CSV ---
for rename_entry in "${RENAMED_FILES[@]}"; do
    echo "$rename_entry" >> "$RENAMED_CSV"
done

# --- SAVE DETAILED REPORT ---
{
  echo "=== Digitalisate Move & Rename Script Report ==="
  echo "Execution time: $(date)"
  echo "Base directory: $BASE_PATH"
  echo "Instruction file: $FILE"
  echo "Dry-run mode: $DRY_RUN"
  echo "Verbose mode: $VERBOSE"
  echo "Total processed rows: $PROCESSED_FILES"
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
success "File rename list saved: $RENAMED_CSV"
success "All operations completed!"

if [ "$DRY_RUN" = true ]; then
  info "This was a dry-run. Remove -n parameter for real changes."
fi
