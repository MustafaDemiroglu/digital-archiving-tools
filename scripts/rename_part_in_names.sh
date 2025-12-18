#!/bin/bash

# =============================================================================
# SCRIPT: Rename Part in File and Directory Names
# =============================================================================
# DESCRIPTION:
#   This script renames all files and directories that contain a specific 
#   string in their names. It replaces the old string with a new string.
#
# HOW IT WORKS:
#   1. Searches for all files and directories containing the old string
#   2. Separates files and directories, processing files first
#   3. Processes directories from deepest to shallowest (bottom-up)
#   4. Shows a preview of changes and asks for confirmation
#   5. Performs the renaming and logs results
#
# USAGE:
#   ./rename_part_in_names.sh <old_string> <new_string>
#
# EXAMPLE:
#   ./rename_part_in_names.sh hainsdorf haindorf
#
# =============================================================================

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <old_string> <new_string>"
    exit 1
fi

OLD=$1
NEW=$2
SUCCESS_LOG="rename_success.log"
ERROR_LOG="rename_error.log"

# Find all items with the old string
mapfile -t all_items < <(find . -depth -name "*$OLD*")

if [ ${#all_items[@]} -eq 0 ]; then
    echo "No files or directories found with '$OLD' in their names."
    echo "There will be no renamed files or dirs."
    exit 0
fi

# Separate files and directories
files_to_rename=()
dirs_to_rename=()

for item in "${all_items[@]}"; do
    if [ -f "$item" ]; then
        files_to_rename+=("$item")
    elif [ -d "$item" ]; then
        dirs_to_rename+=("$item")
    fi
done

# Show preview of all changes
echo "The following renames will be performed:"
echo ""
echo "--- FILES ---"
for fname in "${files_to_rename[@]}"; do
    newname=$(echo "$fname" | sed "s/$OLD/$NEW/g")
    echo "'$fname' --> '$newname'"
done

echo ""
echo "--- DIRECTORIES (will be renamed from deepest to shallowest) ---"
for dname in "${dirs_to_rename[@]}"; do
    newname=$(echo "$dname" | sed "s/$OLD/$NEW/g")
    echo "'$dname' --> '$newname'"
done

echo ""
read -p "Do you want to proceed with these changes? (yes/no): " answer
if ! [[ "$answer" =~ ^(ja|j|yes|y)$ ]]; then
    echo "Rename operation cancelled."
    exit 0
fi

# Clear log files
> "$SUCCESS_LOG"
> "$ERROR_LOG"

echo "Starting renaming... it can take a while if you have a lot to rename"
echo ""

# First, rename all FILES
echo "Renaming files..."
for fname in "${files_to_rename[@]}"; do
    newname=$(echo "$fname" | sed "s/$OLD/$NEW/g")
    if mv -v -- "$fname" "$newname" 2>>"$ERROR_LOG"; then
        echo "SUCCESS: '$fname' -> '$newname'" >> "$SUCCESS_LOG"
    else
        echo "ERROR: Failed to rename '$fname' to '$newname'" >> "$ERROR_LOG"
    fi
done

# Then, rename all DIRECTORIES (already in depth-first order from find -depth)
echo "Renaming directories (from deepest to shallowest)..."
for dname in "${dirs_to_rename[@]}"; do
    newname=$(echo "$dname" | sed "s/$OLD/$NEW/g")
    if mv -v -- "$dname" "$newname" 2>>"$ERROR_LOG"; then
        echo "SUCCESS: '$dname' -> '$newname'" >> "$SUCCESS_LOG"
    else
        echo "ERROR: Failed to rename '$dname' to '$newname'" >> "$ERROR_LOG"
    fi
done

echo ""
echo "Renaming completed."
echo "Successful renames logged in $SUCCESS_LOG"
echo "Failed renames logged in $ERROR_LOG"
echo ""

read -p "Do you want to open the success log file? (yes/no): " open_answer
if [[ "$open_answer" =~ ^(ja|j|yes|y)$ ]]; then
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$SUCCESS_LOG"
    elif command -v open >/dev/null 2>&1; then
        open "$SUCCESS_LOG"
    else
        less "$SUCCESS_LOG"
    fi
fi