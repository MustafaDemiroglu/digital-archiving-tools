#!/usr/bin/env bash
###############################################################################
# Script Name: move_folder.sh (Version: 3.4)
# Author: Mustafa Demiroglu
# Description:
#   This script reads a CSV file that contains a list of folder paths (one per line).
#   It synchronizes each folder into a target directory using rsync, then verifies
#   file integrity with per-file SHA-256 checks. Only after successful verification
#   are source files removed. If verification fails, the source is kept and an
#   error is recorded.
#   - Reliable logging and error reporting even with parallel execution.
#   - Preserves full source directory structure under the target directory,
#     with custom rules for specific base paths.
#
# Features:
#   - Dry-run mode (preview actions without changes).
#   - Per-file checksum verification (sha256).
#   - Structured logging with timestamps (script.log).
#   - Error report CSV for failures (errors.csv).
#   - Optional parallel execution with GNU parallel.
#
# Usage:
#   ./csv_folder_sync.sh -c input.csv -t /path/to/target [-n|--dry-run] [-p N|--parallel N]
#
# CSV format:
#   Each line contains ONE absolute or relative folder path.
###############################################################################

# Colors for readability
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Defaults
CSV_FILE=""
TARGET_DIR=""
DRY_RUN=false
PARALLEL_JOBS=1
VERBOSE=false   # <--- [1] verbose modu eklendi

# Date/Time for log naming
SCRIPT_BASENAME="move_folder"
RUN_DATUM="$(date +'%Y%m%d_%H%M%S')"
LOG_FILE="log_${SCRIPT_BASENAME}_${RUN_DATUM}.log"
ERROR_FILE="error_${SCRIPT_BASENAME}_${RUN_DATUM}.csv"

# --- Utility: usage ---
print_usage() {
  echo -e "${YELLOW}CSV Folder Sync (with per-file checksum verification)${NC}"
  echo "This script copies folders from a CSV list into a target directory,"
  echo "verifies files with SHA-256, then removes source files only if verified."
  echo
  echo "Usage:"
  echo "  $0 -c input.csv -t /path/to/target [-n|--dry-run] [-p N|--parallel N] [-v|--verbose]"
  echo
  echo "Options:"
  echo "  -c FILE       Path to CSV file containing folder paths (one per line)."
  echo "  -t DIR        Target directory where folders will be placed."
  echo "  -n, --dry-run Show planned actions without copying/removing files."
  echo "  -p N, --parallel N  Run N parallel jobs (requires GNU parallel)."
  echo "  -v, --verbose Print log messages also to the terminal."
  echo
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CSV_FILE="$2"; shift 2;;
    -t) TARGET_DIR="$2"; shift 2;;
    -n|--dry-run) DRY_RUN=true; shift;;
    -p|--parallel) PARALLEL_JOBS="$2"; shift 2;;
    -v|--verbose) VERBOSE=true; shift;;   # <--- [2] verbose parametresi
    -h|--help) print_usage; exit 0;;
    *) echo -e "${RED}Unknown option: $1${NC}"; print_usage; exit 1;;
  esac
done

# --- Checks ---
[[ -z "$CSV_FILE" || -z "$TARGET_DIR" ]] && { print_usage; exit 1; }
[[ ! -f "$CSV_FILE" ]] && { echo -e "${RED}Error: CSV not found -> $CSV_FILE${NC}"; exit 1; }
[[ ! -d "$TARGET_DIR" ]] && { echo -e "${RED}Error: Target dir not found -> $TARGET_DIR${NC}"; exit 1; }

# Required binaries
for bin in rsync sha256sum; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo -e "${RED}Error: '$bin' is required but not found in PATH.${NC}"
    exit 1
  fi
done

# Parallel optional
if command -v parallel >/dev/null 2>&1; then
  PARALLEL_AVAILABLE=true
else
  if [[ "$PARALLEL_JOBS" -gt 1 ]]; then
    echo -e "${YELLOW}Warning: GNU parallel not found. Falling back to single job.${NC}"
    PARALLEL_JOBS=1
  fi
fi

# --- Logging helpers (no flock, no env) ---
log_lock_write() {
  # $1 = file, $2... = message
  # Logging is done by opening, appending and closing per call (to avoid problems with flock and env in subshells)
  local file="$1"; shift
  local msg="$(printf "%s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*")"
  printf "%s\n" "$msg" >> "$file"
  if [[ "$VERBOSE" == true ]]; then    # <--- [3] verbose terminal print
    printf "%s\n" "$msg"
  fi
}

append_error_csv() {
  # $1=error_file, $2=folder, $3=relpath, $4=etype, $5=msg
  # Appends to error CSV using exclusive append, no flock
  local file="$1"
  local folder="$2"
  local relpath="$3"
  local etype="$4"
  local msg="$5"
  printf "\"%s\",\"%s\",\"%s\",\"%s\"\n" "$folder" "$relpath" "$etype" "$msg" >> "$file"
}

# Init outputs
echo "==== Run at $(date) ====" >> "$LOG_FILE"
# Write header only if not exists or empty
if [[ ! -s "$ERROR_FILE" ]]; then
  echo "folder,relative_path,error_type,message" > "$ERROR_FILE"
fi

# --- Core worker: process one folder ---
# Main function: copies the source folder to the target, preserving path structure according to base-path rules.

process_folder() {
  local orig_folder="$1"
  local dry="$2"
  local target="$3"
  local log_file="$4"
  local err_file="$5"

  [[ -z "$orig_folder" ]] && return 0

 # --- Normalize paths ---
 # Trim whitespace and Windows CR (\r) if present
  local folder="$(echo "$orig_folder" | tr -d '\r' | xargs)"
  # Replace Windows-style backslashes with forward slashes 
  folder="$(echo "$folder" | sed 's#\\#/#g')"

  # Alt yol substring logic için normalize: başındaki çift/kesirli slash'lar silinsin
  folder="$(echo "$folder" | sed 's#^/*##')"
  folder="/$folder"

  # Remove trailing slash for clean relpaths
  folder="${folder%/}"

  if [[ ! -d "$folder" ]]; then
    log_lock_write "$log_file" "[ERROR] Not a directory -> $folder"
    append_error_csv "$err_file" "$folder" "" "not_a_directory" "Source path is not a directory"
    return 0
  fi

  # --------- Begin: Custom destination path logic -----------
  # Base roots substring mantigi: eger path'in herhangi bir yerine "/media/archive/www" veya "/media/cepheus" varsa, ilk gecen yerden itibaren substring çıkarılır.
  local abs_base=""
  local base1="/media/archive/www"
  local base2="/media/cepheus"
  if [[ "$folder" == "$base1"* ]]; then
    abs_base="${folder:${#base1}}"
    abs_base="${abs_base#/}"
  elif [[ "$folder" == "$base2"* ]]; then
    abs_base="${folder:${#base2}}"
    abs_base="${abs_base#/}"
  else
    abs_base="${folder#/}"
  fi
  local dest="$target/$abs_base"
  # --------- End: Custom destination path logic -------------

  # Create parent directories for the destination
  mkdir -p "$dest"

  if [[ "$dry" == true ]]; then
    log_lock_write "$log_file" "[DRY RUN] Would rsync: '$folder/' -> '$dest/'"
    rsync -a --dry-run "$folder/" "$dest/"
    return 0
  fi

  # 1) Copy (no removal yet)
  log_lock_write "$log_file" "[INFO] Rsync copy start: '$folder/' -> '$dest/'"
  if ! rsync -a "$folder/" "$dest/"; then
    log_lock_write "$log_file" "[ERROR] Rsync failed for -> $folder"
    append_error_csv "$err_file" "$folder" "" "rsync_failed" "rsync returned non-zero exit code"
    return 0
  fi
  log_lock_write "$log_file" "[INFO] Rsync copy done: '$folder/' -> '$dest/'"

  # 2) Verify per-file checksum
  local mismatches=0 missing=0 verified=0 total=0

  # Iterate files in source; compare with corresponding file in dest
  while IFS= read -r -d '' src_file; do
    total=$((total+1))
    # Build relative path
	local rel="${src_file#"$folder/"}"
    local dst_file="$dest/$rel"
    if [[ ! -f "$dst_file" ]]; then
      missing=$((missing+1))
      append_error_csv "$err_file" "$folder" "$rel" "missing_destination" "Destination file not found after copy"
      continue
    fi
	# Compute SHA-256 for src and dest
    local src_hash dst_hash
    src_hash="$(sha256sum "$src_file" | awk '{print $1}')"
    dst_hash="$(sha256sum "$dst_file" | awk '{print $1}')"
    if [[ "$src_hash" != "$dst_hash" ]]; then
      mismatches=$((mismatches+1))
      append_error_csv "$err_file" "$folder" "$rel" "checksum_mismatch" "SHA-256 differs (src!=dst)"
    else
      verified=$((verified+1))
    fi
  done < <(find "$folder" -type f -print0)

  if (( mismatches == 0 && missing == 0 )); then
    log_lock_write "$log_file" "[OK] Verified: $verified/$total files for '$folder'"
	# 3) Remove source files (safe to delete now)
	find "$folder" -type f -print0 | xargs -0 -r rm -f
	# Remove now-empty directories
	find "$folder" -type d -empty -delete
    log_lock_write "$log_file" "[OK] Source removed after verify -> $folder"
  else
    log_lock_write "$log_file" "[ERROR] Verify failed for '$folder' (verified=$verified, missing=$missing, mismatches=$mismatches, total=$total). Source kept."
  fi
}

export -f process_folder log_lock_write append_error_csv

echo -e "${GREEN}Starting folder sync process...${NC}"
echo -e "${CYAN}CSV:${NC} $CSV_FILE"
echo -e "${CYAN}Target:${NC} $TARGET_DIR"
echo -e "${CYAN}Dry run:${NC} $DRY_RUN"
echo -e "${CYAN}Parallel jobs:${NC} $PARALLEL_JOBS"
echo -e "${CYAN}Log file:${NC} $LOG_FILE"
echo -e "${CYAN}Error file:${NC} $ERROR_FILE"
echo -e "${CYAN}Verbose:${NC} $VERBOSE"
echo "----------------------------------------"

# --- Dispatch work ---
if [[ "$PARALLEL_JOBS" -gt 1 && "$PARALLEL_AVAILABLE" == true ]]; then
  # Feed non-empty lines to parallel
  grep -v '^[[:space:]]*$' "$CSV_FILE" | parallel -j "$PARALLEL_JOBS" --will-cite --no-notice process_folder {} "$DRY_RUN" "$TARGET_DIR" "$LOG_FILE" "$ERROR_FILE"
else
  # Sequential
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    process_folder "$line" "$DRY_RUN" "$TARGET_DIR" "$LOG_FILE" "$ERROR_FILE"
  done < "$CSV_FILE"
fi

echo "----------------------------------------"
echo -e "${GREEN}Process completed.${NC}"
echo "Logs: $LOG_FILE"
echo "Errors: $ERROR_FILE"
