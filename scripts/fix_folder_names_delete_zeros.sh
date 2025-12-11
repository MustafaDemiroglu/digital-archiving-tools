#!/usr/bin/env bash

###############################################################################
# Script Name: fix_folder_names_delete_zeros.sh 
# Version: 2.2 
# Author: Mustafa Demiroglu
# Organisation: HlaDigiTeam
#
# Description:
#   Fixes folder names by removing leading zeros from ANY digit-only segment.
#   Segments may be separated by '--', '..', '_' or even be inside text.
#   Supports dry-run mode (-n or --dry-run).
#   Processes only depth 1 and depth 2 subfolders from BASE_DIR.
#
#   Examples:
#     0014                -> 14
#     0014--007           -> 14--7
#     15_006              -> 15_6
#     frankfurt--18_007   -> frankfurt--18_7
#     0018..004--frankfurt -> 18..4--frankfurt
#     frankfurt0015       -> frankfurt15
#
#   All changes are logged into rename_log.txt
###############################################################################

set -euo pipefail

BASE_DIR="."
DRYRUN=0
LOGFILE="rename_log.txt"

usage() {
  cat <<EOF
Usage: $0 [-n|--dry-run] [BASE_DIR]
  -n, --dry-run   Do not perform moves, only log what would be done.
  BASE_DIR        Base directory to scan (default: .)
EOF
  exit 1
}

# ------------- ARG PARSE -----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRYRUN=1; shift ;;
    -h|--help) usage ;;
    *) BASE_DIR="$1"; shift ;;
  esac
done
# ------------------------------------------

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }

# Log header
echo "==== Folder Rename Started at $(timestamp) ====" >> "$LOGFILE"
echo "BASE_DIR: $BASE_DIR" >> "$LOGFILE"
if [[ $DRYRUN -eq 1 ]]; then
  echo "(DRY RUN MODE)" >> "$LOGFILE"
fi

# Terminal: start message
if [[ $DRYRUN -eq 1 ]]; then
  echo "Starting folder rename (DRY RUN) at $(timestamp)"
else
  echo "Starting folder rename at $(timestamp)"
fi

# Function: fix name by removing leading zeros from every digit-only segment
fix_name() {
  local name="$1"
  # Use perl to replace every digit sequence: strip leading zeros, but leave single '0' if all zeros
  # Example: 00150_010--0070 -> 150_10--70
  printf '%s' "$name" | perl -pe 's/(\d+)/ do { my $m=$1; $m=~s/^0+//; $m eq "" ? "0" : $m } /ge'
}

# Collect directories: depth 2 first, then depth 1
mapfile -t DEPTH2 < <(find "$BASE_DIR" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | sort)
mapfile -t DEPTH1 < <(find "$BASE_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

# Combine: depth2 first, then depth1
DIRLIST=()
if [[ ${#DEPTH2[@]} -gt 0 ]]; then
  DIRLIST+=("${DEPTH2[@]}")
fi
if [[ ${#DEPTH1[@]} -gt 0 ]]; then
  DIRLIST+=("${DEPTH1[@]}")
fi

TOTAL=${#DIRLIST[@]}
COUNT=0

if [[ $TOTAL -eq 0 ]]; then
  echo "No directories found under '$BASE_DIR' (depth 1..2)."
  echo "==== Folder Rename Finished at $(timestamp) ====" >> "$LOGFILE"
  echo "Done."
  exit 0
fi

# Main loop
for dir in "${DIRLIST[@]}"; do
  COUNT=$((COUNT + 1))
  percent=$(( COUNT * 100 / TOTAL ))
  # Terminal: only progress line (overwrites)
  printf 'Progress: %3d%%\r' "$percent"

  name=$(basename "$dir")
  parent=$(dirname "$dir")
  newname=$(fix_name "$name")

  # If unchanged, skip quietly
  if [[ "$name" == "$newname" ]]; then
    continue
  fi

  oldpath="$parent/$name"
  newpath="$parent/$newname"

  if [[ -e "$newpath" ]]; then
    echo "WARNING: target exists, skipping: $oldpath -> $newpath" >> "$LOGFILE"
    continue
  fi

  if [[ $DRYRUN -eq 1 ]]; then
    echo "[DRY-RUN] $oldpath --> $newpath" >> "$LOGFILE"
  else
    if mv -- "$oldpath" "$newpath"; then
      echo "$oldpath --> $newpath" >> "$LOGFILE"
    else
      echo "ERROR: failed to mv $oldpath -> $newpath" >> "$LOGFILE"
    fi
  fi
done

# Ensure progress shows 100% then newline
printf 'Progress: 100%%\n'

# Footer
echo "==== Folder Rename Finished at $(timestamp) ====" >> "$LOGFILE"
echo "Done."