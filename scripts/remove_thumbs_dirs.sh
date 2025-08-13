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
#   4. Before deletion, you will be asked to confirm (y/n).
#   5. Successfully deleted folders will be recorded in "deleted_thumbs.list".
#
# WARNING:
#   This operation is permanent. Deleted files cannot be recovered.
###############################################################################

# Step 1: Determine target directory
TARGET_DIR="${1:-$(pwd)}"
OUTPUT_FILE="$(pwd)/deleted_thumbs.list"

# Step 2: Check if directory exists
if [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Directory '$TARGET_DIR' does not exist."
    exit 1
fi

echo "Searching for 'thumbs' folders in: $TARGET_DIR"
echo "----------------------------------------------"

# Step 3: Find all 'thumbs' directories
MAPFILE -t THUMBS_DIRS < <(find "$TARGET_DIR" -type d -name "thumbs")

if [ ${#THUMBS_DIRS[@]} -eq 0 ]; then
    echo "No 'thumbs' folders found."
    exit 0
fi

echo "Found ${#THUMBS_DIRS[@]} 'thumbs' folders:"
for dir in "${THUMBS_DIRS[@]}"; do
    echo "  $dir"
done

# Step 4: Ask for confirmation
read -rp "Do you want to delete all these folders? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Operation cancelled."
    exit 0
fi

# Step 5: Clear or create output file
> "$OUTPUT_FILE"

# Step 6: Delete each folder and log results
for dir in "${THUMBS_DIRS[@]}"; do
    REL_PATH=$(realpath --relative-to="$(pwd)" "$dir")
    if rm -rf "$dir"; then
        echo "$REL_PATH" >> "$OUTPUT_FILE"
        echo "Deleted: $REL_PATH"
    else
        echo "Failed to delete: $REL_PATH"
    fi
done

echo "----------------------------------------------"
echo "Process finished."
echo "Deleted folders list saved to: $OUTPUT_FILE"
