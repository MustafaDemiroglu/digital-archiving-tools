#!/usr/bin/env bash
###############################################################################
# Script Name: folder_sync_from_csv.sh
# Description:
#   This script reads a CSV file that contains a list of folder paths (one per line).
#   It synchronizes each folder into a target directory using rsync, then verifies
#   file integrity with per-file SHA-256 checks. Only after successful verification
#   are source files removed. If verification fails, the source is kept and an
#   error is recorded.
#
# Features:
#   - Dry-run mode (preview actions without changes).
#   - Per-file checksum verification (sha256).
#   - Structured logging with timestamps (script.log).
#   - Error report CSV for failures (errors.csv).
#   - Optional parallel execution with GNU parallel.
#
# Usage:
#   ./csv_folder_sync.sh -c input.csv -t /path/to/target [--dry-run] [--parallel N]
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
LOG_FILE="script.log"
ERROR_FILE="errors.csv"

# --- Utility: usage ---
print_usage() {
  echo -e "${YELLOW}CSV Folder Sync (with per-file checksum verification)${NC}"
  echo "This script copies folders from a CSV list into a target directory,"
  echo "verifies files with SHA-256, then removes source files only if verified."
  echo
  echo "Usage:"
  echo "  $0 -c input.csv -t /path/to/target [--dry-run] [--parallel N]"
  echo
  echo "Options:"
  echo "  -c FILE       Path to CSV file containing folder paths (one per line)."
  echo "  -t DIR        Target directory where folders will be placed."
  echo "  --dry-run     Show planned actions without copying/removing files."
  echo "  --parallel N  Run N parallel jobs (requires GNU parallel)."
  echo
}

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c) CSV_FILE="$2"; shift 2;;
    -t) TARGET_DIR="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --parallel) PARALLEL_JOBS="$2"; shift 2;;
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
PARALLEL_AVAILABLE=false
if command -v parallel >/dev/null 2>&1; then
  PARALLEL_AVAILABLE=true
else
  if [[ "$PARALLEL_JOBS" -gt 1 ]]; then
    echo -e "${YELLOW}Warning: GNU parallel not found. Falling back to single job.${NC}"
    PARALLEL_JOBS=1
  fi
fi

# --- Logging helpers (with flock for safe concurrent writes) ---
log_lock_write() {
  # $1 = file, $2... = message
  local file="$1"; shift
  {
    flock -x 200
    printf "%s %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
  } 200>>"$file"
}

append_error_csv() {
  # CSV columns: folder,relative_path,error_type,message
  local folder="$1"
  local relpath="$2"
  local etype="$3"
  local msg="$4"
  {
    flock -x 200
    printf "\"%s\",\"%s\",\"%s\",\"%s\"\n" "$folder" "$relpath" "$etype" "$msg"
  } 200>>"$ERROR_FILE"
}

# Init outputs
echo "==== Run at $(date) ====" >> "$LOG_FILE"
# Write header only if not exists or empty
if [[ ! -s "$ERROR_FILE" ]]; then
  echo "folder,relative_path,error_type,message" > "$ERROR_FILE"
fi

# --- Core worker: process one folder ---
process_folder() {
  local folder="$1"
  local dry="$2"
  local target="$3"

  [[ -z "$folder" ]] && return 0

  # --- Normalize paths ---
  # Trim whitespace and Windows CR (\r) if present
  folder="$(echo "$folder" | tr -d '\r' | xargs)"

  # Replace Windows-style backslashes with forward slashes
  folder="$(echo "$folder" | sed 's#\\#/#g')"

  # Ensure absolute path (add leading "/" if missing)
  if [[ "$folder" != /* ]]; then
    folder="/$folder"
  fi

  # Remove trailing slash for clean relpaths
  folder="${folder%/}"

  if [[ ! -d "$folder" ]]; then
    log_lock_write "$LOG_FILE" "[ERROR] Not a directory -> $folder"
    append_error_csv "$folder" "" "not_a_directory" "Source path is not a directory"
    return 0
  fi

  local fname dest
  fname="$(basename "$folder")"
  dest="$target/$fname"

  if [[ "$dry" == true ]]; then
    log_lock_write "$LOG_FILE" "[DRY RUN] Would rsync: '$folder/' -> '$dest/'"
    rsync -a --dry-run "$folder/" "$dest/"
    return 0
  fi

  # 1) Copy (no removal yet)
  log_lock_write "$LOG_FILE" "[INFO] Rsync copy start: '$folder/' -> '$dest/'"
  if ! rsync -a "$folder/" "$dest/"; then
    log_lock_write "$LOG_FILE" "[ERROR] Rsync failed for -> $folder"
    append_error_csv "$folder" "" "rsync_failed" "rsync returned non-zero exit code"
    return 0
  fi
  log_lock_write "$LOG_FILE" "[INFO] Rsync copy done: '$folder/' -> '$dest/'"

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
      append_error_csv "$folder" "$rel" "missing_destination" "Destination file not found after copy"
      continue
    fi

    # Compute SHA-256 for src and dest
    local src_hash dst_hash
    src_hash="$(sha256sum "$src_file" | awk '{print $1}')"
    dst_hash="$(sha256sum "$dst_file" | awk '{print $1}')"

    if [[ "$src_hash" != "$dst_hash" ]]; then
      mismatches=$((mismatches+1))
      append_error_csv "$folder" "$rel" "checksum_mismatch" "SHA-256 differs (src!=dst)"
    else
      verified=$((verified+1))
    fi
  done < <(find "$folder" -type f -print0)

  if (( mismatches == 0 && missing == 0 )); then
    log_lock_write "$LOG_FILE" "[OK] Verified: $verified/$total files for '$folder'"
    # 3) Remove source files (safe to delete now)
    find "$folder" -type f -print0 | xargs -0 -r rm -f
    # Remove now-empty directories
    find "$folder" -type d -empty -delete
    log_lock_write "$LOG_FILE" "[OK] Source removed after verify -> $folder"
  else
    log_lock_write "$LOG_FILE" "[ERROR] Verify failed for '$folder' (verified=$verified, missing=$missing, mismatches=$mismatches, total=$total). Source kept."
  fi
}

export -f process_folder log_lock_write append_error_csv
export LOG_FILE ERROR_FILE

echo -e "${GREEN}Starting folder sync process...${NC}"
echo -e "${CYAN}CSV:${NC} $CSV_FILE"
echo -e "${CYAN}Target:${NC} $TARGET_DIR"
echo -e "${CYAN}Dry run:${NC} $DRY_RUN"
echo -e "${CYAN}Parallel jobs:${NC} $PARALLEL_JOBS"
echo "----------------------------------------"

# --- Dispatch work ---
if [[ "$PARALLEL_JOBS" -gt 1 && "$PARALLEL_AVAILABLE" == true ]]; then
  # Feed non-empty lines to parallel
  grep -v '^[[:space:]]*$' "$CSV_FILE" | parallel -j "$PARALLEL_JOBS" --will-cite --no-notice process_folder {} "$DRY_RUN" "$TARGET_DIR"
else
  # Sequential
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    process_folder "$line" "$DRY_RUN" "$TARGET_DIR"
  done < "$CSV_FILE"
fi

echo "----------------------------------------"
echo -e "${GREEN}Process completed.${NC}"
echo "Logs: $LOG_FILE"
echo "Errors: $ERROR_FILE"