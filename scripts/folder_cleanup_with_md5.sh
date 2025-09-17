#!/bin/bash

###############################################################################
# Script Name : folder_cleanup_with_md5.sh
# Version: 2.5
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
#   3. If all files compares -> move ALL files.
#   4. If only some files are identical -> move those identical files.
#   5. Moves are done to ./_tmp_cleanup/<folder>/.
#   6. If an md5 checksum file is provided, lines for moved files are removed.
###############################################################################

MD5_FILE="$1"
TMP_DIR="./_tmp_cleanup"
datum=$(date +%Y%m%d_%H%M%S)

LOG_FILE="log_script_$datum.log"
echo "Logging started for $datum" > "$LOG_FILE"

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

  echo "Processing: $folder_clean" | tee -a "$LOG_FILE"

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
    echo "  → All files identical. Moving entire folder." | tee -a "$LOG_FILE"
    dest="$TMP_DIR/$folder_clean"
    mkdir -p "$(dirname "$dest")"
    rsync -av --remove-source-files "$folder_clean" "$dest" | tee -a "$LOG_FILE"
    # Remove MD5 entries for entire folder if file provided
    if [[ -f "$MD5_FILE" ]]; then
      grep -v "$folder_clean/" "$MD5_FILE" > "${MD5_FILE}.tmp" && mv "${MD5_FILE}.tmp" "$MD5_FILE"
    fi
  else
    if [[ ${#identical_files[@]} -gt 0 ]]; then
      echo "  → ${#identical_files[@]} identical file(s) found. Moving them." | tee -a "$LOG_FILE"
      for f in "${identical_files[@]}"; do
        dest="$TMP_DIR/$f"
        mkdir -p "$(dirname "$dest")"
        mv "$f" "$dest" | tee -a "$LOG_FILE"
        # Remove MD5 entry if file provided
        if [[ -f "$MD5_FILE" ]]; then
          grep -v "  $f\$" "$MD5_FILE" > "${MD5_FILE}.tmp" && mv "${MD5_FILE}.tmp" "$MD5_FILE"
        fi
      done
    else
      echo "  → No identical files. Nothing to move." | tee -a "$LOG_FILE"
    fi
  fi
}

# Main
echo "Starting cleanup before move ingest to cepheus" | tee -a "$LOG_FILE"
echo "Finding folders to check... It can take some time ..." | tee -a "$LOG_FILE"

Skip empty folders
mapfile -t folders < <(find . -mindepth 1 -type d ! -empty ! -exec sh -c 'find "$1" -mindepth 1 -type d | grep -q .' sh {} \; -print | sort)

echo "Checking folders started." | tee -a "$LOG_FILE"
for folder in "${folders[@]}"; do
  process_folder "$folder"
done

# MD5 checksum for the moved files
echo "Checksum for $TMP_DIR started " | tee -a "$LOG_FILE"
find ./$TMP_DIR/ -type f | sort | xargs md5sum > ./$TMP_DIR/deleted_files_$datum.md5

echo "Cleanup finished. Check $TMP_DIR for moved items." | tee -a "$LOG_FILE"