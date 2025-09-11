#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# delete_pdfs_with_list.sh
# version 1.1
# Author: Mustafa Demiroglu
#
# Description:
#   This script deletes all PDF files located inside a set of directories that
#   are provided in a text file (one directory path per line).
#
#   It never touches any other file types, only *.pdf files. It will not delete
#   anything outside the directories listed in the input file.
#
# How it works:
#   1. You provide a file (txt, csv, .list, etc.) containing one directory path
#      per line.
#   2. The script reads the file line by line.
#   3. For each directory path:
#        - In dry-run mode, it shows which PDF files *would* be deleted,
#          without deleting them.
#        - In normal mode, it first lists the PDF files found, warns that
#          deletion is permanent, asks for confirmation, and then deletes them.
#   4. Verbose mode prints additional information about progress.
#
# Features:
#   - --dry-run / -n : simulate only, show what would be deleted
#   - --verbose / -v : print extra progress messages
#   - --help / -h    : show usage
#
# Safety:
#   - If a directory in the list does not exist, it is skipped with a warning.
#   - Deletion is confirmed by user input before proceeding.
#   - Only files matching "*.pdf" are considered.
#
# Usage example:
#   ./delete_pdfs_from_list.sh -n myfolders.list
#   ./delete_pdfs_from_list.sh -v myfolders.txt
#
# -----------------------------------------------------------------------------

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

# Read list file line by line
while IFS= read -r dir; do
  # Skip empty lines and comments
  [[ -z "$dir" ]] && continue
  [[ "$dir" =~ ^# ]] && continue

  if [[ ! -d "$dir" ]]; then
    echo "[WARN] Directory does not exist: $dir" >&2
    continue
  fi

  if (( VERBOSE )); then
    echo "[INFO] Processing directory: $dir"
  fi

  # Find PDFs
  pdfs=$(find "$dir" -type f -name "*.pdf" 2>/dev/null)
  if [[ -z "$pdfs" ]]; then
    echo "[INFO] No PDF files found in: $dir"
    continue
  fi

  echo "---------------------------------------------"
  echo "PDF files in: $dir"
  echo "$pdfs"
  echo "---------------------------------------------"

  if (( DRY_RUN )); then
    echo "[DRY-RUN] Would delete the above files."
  else
    echo "WARNING: The above PDF files will be permanently deleted!"
    read -p "Do you want to proceed? (yes/no): " answer
    case "$answer" in
      yes|y|Y)
        if (( VERBOSE )); then
          echo "[INFO] Deleting PDFs in: $dir"
        fi
        # Actually delete and show each file
        find "$dir" -type f -name "*.pdf" -print -delete
        echo "[OK] Deletion complete for $dir"
        ;;
      *)
        echo "[SKIP] Skipped deletion for $dir"
        ;;
    esac
  fi

done < "$LISTFILE"

echo "[DONE] Script finished."
