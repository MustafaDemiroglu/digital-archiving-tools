#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# delete_pdfs_with_list.sh
# version 1.2
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

set -euo pipefail

show_help() {
    grep '^#' "$0" | sed 's/^#//'
    exit 0
}

if [[ $# -lt 1 ]]; then
    echo "[ERROR] Missing arguments."
    echo "Usage: $0 <list_file> [--dry-run]"
    exit 1
fi

LIST_FILE="$1"
DRY_RUN=false

if [[ "${2:-}" == "--help" ]]; then
    show_help
elif [[ "${2:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

if [[ ! -f "$LIST_FILE" ]]; then
    echo "[ERROR] List file not found: $LIST_FILE"
    exit 1
fi

ALL_PDFS=()

# Collect PDFs from each listed directory
while IFS= read -r dir || [[ -n "$dir" ]]; do
    [[ -z "$dir" ]] && continue
    if [[ ! -d "$dir" ]]; then
        echo "[WARN] Directory does not exist: $dir"
        continue
    fi
    while IFS= read -r pdf; do
        ALL_PDFS+=("$pdf")
    done < <(find "$dir" -type f -name "*.pdf")
done < "$LIST_FILE"

if [[ ${#ALL_PDFS[@]} -eq 0 ]]; then
    echo "[INFO] No PDF files found to process."
    exit 0
fi

echo "---------------------------------------------"
echo "PDF files identified:"
printf '%s\n' "${ALL_PDFS[@]}"
echo "---------------------------------------------"

if $DRY_RUN; then
    echo "[DRY-RUN] No files were deleted. (This was only a simulation)"
    exit 0
fi

echo "WARNING: The above PDF files will be permanently deleted!"
read -rp "Do you want to proceed? (y/N): " CONFIRM

if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    for pdf in "${ALL_PDFS[@]}"; do
        echo "[DELETE] $pdf"
        rm -f -- "$pdf"
    done
    echo "[DONE] All selected PDF files have been deleted."
else
    echo "[CANCEL] User did not confirm. No files were deleted."
    exit 0
fi