#!/bin/bash
###############################################################################
# Script Name: remove_thumbs_dirs.sh
#
# Description:
#   This script searches for all folders named "thumbs" inside a given directory
#   (or the current working directory if no path is provided) and deletes them
#   along with all their contents.
#
# How it works:
#   1. You can pass a folder path as the first argument when running the script.
#      Example: ./remove_thumbs_dirs.sh /path/to/project
#   2. If you do not provide a folder path, it will run in the current directory.
#   3. The script will search recursively for all directories named "thumbs".
#   4. It will delete each found "thumbs" directory and its contents.
#
# WARNING:
#   This operation is permanent. Deleted files cannot be recovered.
###############################################################################

# Step 1: Determine target directory
TARGET_DIR="${1:-$(pwd)}"

# Step 2: Check if directory exists
if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Directory '$TARGET_DIR' does not exist."
    exit 1
fi

echo "Searching for 'thumbs' folders in: $TARGET_DIR"
echo "----------------------------------------------Searching 'thumbs' folders"

# Step 3: Find and delete all 'thumbs' folders
find "$TARGET_DIR" -type d -name "thumbs" | while read -r dir; do
    echo "Deleting: $dir"
    rm -rf "$dir"
done

echo "----------------------------------------------Deleting 'thumbs' folders"
echo "All 'thumbs' folders have been deleted."
