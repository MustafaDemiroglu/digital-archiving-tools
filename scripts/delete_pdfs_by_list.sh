#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# delete_pdfs_by_list.sh
# version 1.5
# Author: Mustafa Demiroglu
#
# Description:
#   This script deletes all PDF files located inside a set of directories that
#   are provided in a text file (one directory path per line).
#
#   It never touches any other file types, only *.pdf files. It will not delete
#   anything outside the directories listed in the input file.
#
# Usage:
#   ./delete_pdfs_with_list.sh <list_file> [--dry-run]
#
#   <list_file> : A file containing one directory path per line.
#   --dry-run   : Optional flag. Show files that WOULD be deleted, but do not delete.
#   --help      : Show help and usage instructions.
#
# How it works:
#   1. Reads directories line by line from the provided list file.
#   2. Collects all "*.pdf" files under those directories.
#   3. If dry-run is enabled, it shows the list only.
#   4. If not dry-run:
#        - Displays all found PDF files
#        - Asks ONCE for confirmation
#        - If confirmed, deletes them
#        - If not confirmed, exits without deleting
#
###############################################################################

usage() {
  cat <<USAGE
Usage: $0 [OPTIONS] LISTFILE

Options:
  -n, --dry-run     Show what would be deleted, but do not delete anything.
  -v, --verbose     Print extra progress information.
  -h, --help        Show this help message.

Arguments:
  LISTFILE          A text file containing one directory path per line.
USAGE
}

# Parse options
DRY_RUN=0
VERBOSE=0
LISTFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) LISTFILE="$1"; shift ;;
  esac
done

# Validate input
if [[ -z "$LISTFILE" ]]; then
  echo "Error: no list file specified." >&2
  usage
  exit 1
fi

if [[ ! -f "$LISTFILE" ]]; then
  echo "Error: list file '$LISTFILE' not found." >&2
  exit 1
fi

if (( DRY_RUN )); then
  echo "[INFO] Running in DRY-RUN mode. No files will be deleted."
fi

# Collect all PDFs first
all_pdfs=()
while IFS= read -r dir || [[ -n "$dir" ]]; do
  # Remove possible Windows CR (\r) at the end
  dir="${dir%$'\r'}"

  # Skip empty lines and comments
  [[ -z "$dir" ]] && continue
  [[ "$dir" =~ ^# ]] && continue

  if [[ ! -d "$dir" ]]; then
    echo "[WARN] Directory does not exist: $dir" >&2
    continue
  fi

  if (( VERBOSE )); then
    echo "[INFO] Scanning directory: $dir"
  fi

  mapfile -t pdfs < <(find "$dir" -type f -name "*.pdf" 2>/dev/null || true)
  if [[ ${#pdfs[@]} -eq 0 ]]; then
    if (( VERBOSE )); then
      echo "[INFO] No PDF files found in: $dir"
    fi
    continue
  fi

  all_pdfs+=("${pdfs[@]}")

done < "$LISTFILE"

# If no PDFs at all
if [[ ${#all_pdfs[@]} -eq 0 ]]; then
  echo "[INFO] No PDF files found in any listed directory."
  exit 0
fi

echo "---------------------------------------------"
echo "PDF files found:"
printf '%s\n' "${all_pdfs[@]}"
echo "---------------------------------------------"

if (( DRY_RUN )); then
  echo "[DRY-RUN] Would delete the above files."
else
  read -p "Delete these files? (yes/no): " answer
  case "$answer" in
    yes|y|Y)
      for file in "${all_pdfs[@]}"; do
        rm -v -- "$file"
      done
      echo "[OK] All selected PDF files deleted."
      ;;
    *)
      echo "[INFO] Cancelled by User. Nothing deleted."
      exit 0
      ;;
  esac
fi

echo "[DONE] Script finished."