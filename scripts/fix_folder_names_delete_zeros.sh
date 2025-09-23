#!/usr/bin/env bash
###############################################################################
# Script Name: fix_folder_names_delete_zeros.sh
# Author: Mustafa (Data Steward Style)
#
# Description:
#   This script searches through all subfolders and fixes folder names
#   by removing ALL leading zeros in the second number part.
#   Example: "597--012" -> "597--12", "1--007" -> "1--7"
#
#   All renaming operations are logged into "rename_log.txt"
#
# Usage:
#   bash fix_folder_names.sh /path/to/parent_folder
###############################################################################

BASE_DIR="${1:-.}"     # default: current folder
LOGFILE="rename_log.txt"

echo "==== Folder Rename Started at $(date) ====" >> "$LOGFILE"

find "$BASE_DIR" -type d | while read -r dir; do
  name=$(basename "$dir")
  parent=$(dirname "$dir")

  # if dirname has zero ath the second part
  if [[ "$name" =~ ^([0-9]+)--0*([0-9]+)$ ]]; then
    newname="${BASH_REMATCH[1]}--${BASH_REMATCH[2]}"
    oldpath="$parent/$name"
    newpath="$parent/$newname"

    # if there is not a target folder already
    if [[ ! -e "$newpath" ]]; then
      mv "$oldpath" "$newpath"
      echo "$oldpath  -->  $newpath" | tee -a "$LOGFILE"
    else
      echo "WARNING: $newpath already exists, skipping $oldpath" | tee -a "$LOGFILE"
    fi
  fi
done

echo "==== Folder Rename Finished at $(date) ====" >> "$LOGFILE"
