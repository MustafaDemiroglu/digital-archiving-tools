#!/bin/bash

###############################################################################
# Script Name: find_placeholder_netapp.sh
#
# Description:
# This script searches for possible placeholder images in archive folders.
# A file is considered a placeholder if:
#   - It is the ONLY file inside a signature folder
#   - Its size is smaller than 100 KB
#
# The script DOES NOT modify or delete anything. It only reads files.
# Result is written to: placeholders_in_netapp.csv
#
# Thumbs folders are ignored.
###############################################################################

OUTPUT_FILE="placeholders_in_netapp.csv"
SIZE_LIMIT=102400   # 100 KB in bytes

echo "Path,Filename,Size(Bytes)" > "$OUTPUT_FILE"

# --- Check input path ---
if [ -z "$1" ]; then
    read -p "No path given. Use current directory? (y/n): " answer
    if [ "$answer" != "y" ]; then
        echo "No path to scan. Exiting."
        exit 1
    fi
    BASE_PATH="$(pwd)"
else
    BASE_PATH="$1"
fi

# --- Validate path ---
if [ ! -d "$BASE_PATH" ]; then
    echo "Given path does not exist: $BASE_PATH"
    exit 1
fi

echo "Scanning path: $BASE_PATH"
echo "Please wait..."

# --- Find all potential signature folders ---
find "$BASE_PATH" -type d ! -name "thumbs" | while read -r dir; do

    # Get list of regular files in this folder, excluding thumbs folder content
    mapfile -t files < <(find "$dir" -maxdepth 1 -type f)

    file_count=${#files[@]}

    # We only care if there is exactly ONE file
    if [ "$file_count" -eq 1 ]; then
        file="${files[0]}"
        size=$(stat -c%s "$file" 2>/dev/null)

        if [ -n "$size" ] && [ "$size" -lt "$SIZE_LIMIT" ]; then
            filename=$(basename "$file")
            echo "$dir,$filename,$size" >> "$OUTPUT_FILE"
            echo "Placeholder found: $file"
        fi
    fi

done

echo "Scan finished."
echo "Results saved to: $OUTPUT_FILE"
