#!/bin/bash

###############################################################################
# Script Name : folder_cleanup_with_md5.sh
# Version: 1.1
# Author: Mustafa Demiroglu
# Purpose     : 
#   Move redundant files/folders (instead of deleting) into a temporary folder
#   after comparing with /media/cepheus. Optionally update given MD5 file.
#
# Usage:
#   ./folder_cleanup_with_md5.sh [optional-md5-file]
#
# What it does:
#   1. Finds lowest-level folders in current working directory.
#   2. Compares each with /media/cepheus/<folder>.
#   3. If evaluation says "keine Migration nötig" -> move ALL files.
#   4. If only some files are identical -> move those identical files.
#   5. Moves are done to ./_tmp_cleanup/<folder>/.
#   6. If an md5 checksum file is provided, lines for moved files are removed.
###############################################################################

MD5_FILE="$1"
TMP_DIR="./_tmp_cleanup"

mkdir -p "$TMP_DIR"

# Function: trim path
trim() {
  echo -n "$1" | sed 's#^\./##'
}

# Function: compare MD5 of two files
same_file_md5() {
  local f1="$1"
  local f2="$2"
  [[ ! -f "$f1" || ! -f "$f2" ]] && return 1
  local h1=$(md5sum "$f1" | awk '{print $1}')
  local h2=$(md5sum "$f2" | awk '{print $1}')
  [[ "$h1" == "$h2" ]]
}

# Function: process one folder
process_folder() {
  local folder="$1"
  local folder_clean=$(trim "$folder")
  local cepheus="/media/cepheus/$folder_clean"

  [[ ! -d "$cepheus" ]] && return

  echo "Processing: $folder_clean"

  local all_match=true

  # Track identical files
  identical_files=()

  while IFS= read -r -d '' f; do
    rel=${f#"$folder_clean"/}
    if [[ -f "$cepheus/$rel" ]]; then
      if same_file_md5 "$f" "$cepheus/$rel"; then
        identical_files+=("$f")
      else
        all_match=false
      fi
    else
      all_match=false
    fi
  done < <(find "$folder_clean" -type f -print0)

  if $all_match; then
    echo "  → All files identical. Moving entire folder."
    dest="$TMP_DIR/$folder_clean"
    mkdir -p "$(dirname "$dest")"
    mv "$folder_clean" "$dest"
    # Remove MD5 entries for entire folder if file provided
    if [[ -f "$MD5_FILE" ]]; then
      grep -v "$folder_clean/" "$MD5_FILE" > "${MD5_FILE}.tmp" && mv "${MD5_FILE}.tmp" "$MD5_FILE"
    fi
  else
    if [[ ${#identical_files[@]} -gt 0 ]]; then
      echo "  → ${#identical_files[@]} identical file(s) found. Moving them."
      for f in "${identical_files[@]}"; do
        dest="$TMP_DIR/$f"
        mkdir -p "$(dirname "$dest")"
        mv "$f" "$dest"
        # Remove MD5 entry if file provided
        if [[ -f "$MD5_FILE" ]]; then
          grep -v "  $f\$" "$MD5_FILE" > "${MD5_FILE}.tmp" && mv "${MD5_FILE}.tmp" "$MD5_FILE"
        fi
      done
    else
      echo "  → No identical files. Nothing to move."
    fi
  fi
}

# Main
echo "Starting cleanup..."
mapfile -t folders < <(find . -type d ! -exec sh -c 'find "$1" -mindepth 1 -type d | grep -q .' sh {} \; -print | sort)

for folder in "${folders[@]}"; do
  process_folder "$folder"
done

echo "Cleanup finished. Check $TMP_DIR for moved items."
