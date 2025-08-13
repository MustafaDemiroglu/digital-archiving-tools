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
#   1. You can pass a folder path as the first argument.
#      Example: ./remove_thumbs_dirs.sh /path/to/project
#   2. If you do not provide a folder path, it will run in the current directory.
#   3. Add "-n" or "--dry-run" as the first parameter to run in test mode
#      (no deletion will happen).
#   4. The script will search recursively for all directories named "thumbs".
#   5. In delete mode, it will ask for confirmation (y/n).
#   6. Successfully deleted folders will be recorded in "deleted_thumbs.list".
#
# WARNING:
#   This operation is permanent in delete mode. Deleted files cannot be recovered.
###############################################################################

# Colors
GREEN="\033[0;32m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Step 1: Check if dry-run mode is enabled
DRY_RUN=false
if [[ "$1" == "-n" || "$1" == "--dry-run" ]]; then
    DRY_RUN=true
    shift
fi

# Step 2: Determine target directory
TARGET_DIR="${1:-$(pwd)}"
OUTPUT_FILE="$(pwd)/deleted_thumbs.list"

# Step 3: Check if directory exists
if [ ! -d "$TARGET_DIR" ]; then
    echo -e "${RED}Error:${NC} Directory '$TARGET_DIR' does not exist."
    exit 1
fi

echo "Searching for 'thumbs' folders in: $TARGET_DIR"
echo "----------------------------------------------"

# Step 4: Find all 'thumbs' directories
MAPFILE -t THUMBS_DIRS < <(find "$TARGET_DIR" -type d -name "thumbs")

if [ ${#THUMBS_DIRS[@]} -eq 0 ]; then
    echo -e "${BLUE}No 'thumbs' folders found.${NC}"
    exit 0
fi

echo "Found ${#THUMBS_DIRS[@]} 'thumbs' folders:"
for dir in "${THUMBS_DIRS[@]}"; do
    echo "  $dir"
done

# Step 5: Dry-run mode check
if $DRY_RUN; then
    echo "----------------------------------------------"
    echo -e "${BLUE}Dry-run mode: No folders will be deleted.${NC}"
    exit 0
fi

# Step 6: Ask for confirmation
read -rp "Do you want to delete all these folders? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "${RED}Operation cancelled.${NC}"
    exit 0
fi

# Step 7: Clear or create output file
> "$OUTPUT_FILE"

# Step 8: Delete each folder and log results
for dir in "${THUMBS_DIRS[@]}"; do
    REL_PATH=$(realpath --relative-to="$(pwd)" "$dir")
    if rm -rf "$dir"; then
        echo "$REL_PATH" >> "$OUTPUT_FILE"
        echo -e "${GREEN}Deleted:${NC} $REL_PATH"
    else
        echo -e "${RED}Failed to delete:${NC} $REL_PATH"
    fi
done

echo "----------------------------------------------"
echo -e "${GREEN}Process finished.${NC}"
echo "Deleted folders list saved to: $OUTPUT_FILE"
