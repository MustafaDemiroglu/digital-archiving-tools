#!/bin/bash

############################################################
# Name: check_large_dirs_level1_count.sh
#
# What this script does:
# This script checks directories and their subdirectories.
# For each directory, it counts how many files and folders
# exist in the first level only.
# If the count is 10,000 or more, it writes the result to a CSV file.
#
# How it works:
# - You give one or more directory paths as arguments.
# - The script starts from each path.
# - It scans all subdirectories.
# - It only reads data. No change, no delete.
#
# Usage example:
# ./check_large_dirs_level1_count.sh dir1 dir2 dir3
############################################################

# Output CSV file name
OUTPUT_CSV="large_directories_in_cepheus.csv"

# Write CSV header
echo "directory_path,item_count" > "$OUTPUT_CSV"

# Check if at least one argument is given
if [ "$#" -eq 0 ]; then
  echo "Please give at least one directory path."
  echo "Example: ./check_large_dirs_level1_count.sh /data /home/user"
  exit 1
fi

# Loop over all given paths
for ROOT_PATH in "$@"; do

  # Check if path exists and is a directory
  if [ ! -d "$ROOT_PATH" ]; then
    echo "Path not found or not a directory: $ROOT_PATH"
    echo "This path will be skipped."
    continue
  fi

  echo "Scanning: $ROOT_PATH"

  # Find all directories including the root one
  find "$ROOT_PATH" -type d 2>/dev/null | while read -r DIR; do

    # Count first level files and folders
    COUNT=$(ls -1A "$DIR" 2>/dev/null | wc -l)

    # If count is 10000 or more, write to CSV
    if [ "$COUNT" -ge 10000 ]; then
      echo "\"$DIR\",$COUNT" >> "$OUTPUT_CSV"
    fi

  done

done

echo "Scan finished."
echo "Results are saved in: $OUTPUT_CSV"
