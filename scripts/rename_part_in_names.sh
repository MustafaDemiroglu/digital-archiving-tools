#!/bin/bash

# Usage: ./rename_part_in_names.sh old_string new_string
# Example: ./rename_part_in_names.sh hainsdorf haindorf

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <old_string> <new_string>"
    exit 1
fi

OLD=$1
NEW=$2

SUCCESS_LOG="rename_success.log"
ERROR_LOG="rename_error.log"

# Find all files and dirs with the old string, using depth-first search (bottom-up)
mapfile -t files_to_rename < <(find . -depth -name "*$OLD*")

if [ ${#files_to_rename[@]} -eq 0 ]; then
    echo "No files or directories found with '$OLD' in their names. There will be no renamed files or dirs."
    exit 0
fi

echo "The following renames will be performed:"
for fname in "${files_to_rename[@]}"; do
    newname=$(echo "$fname" | sed "s/$OLD/$NEW/g")
    echo "'$fname'  -->  '$newname'"
done

read -p "Do you want to proceed with these changes? (yes/no): " answer
if ! [[ "$answer" =~ ^(ja|j|evet|e|yes|y)$ ]]; then
    echo "Rename operation cancelled."
    exit 0
fi

# Clear log files
> "$SUCCESS_LOG"
> "$ERROR_LOG"

echo "Starting renaming... it can take a while if you have a lot to rename"

for fname in "${files_to_rename[@]}"; do
    newname=$(echo "$fname" | sed "s/$OLD/$NEW/g")
    
    if mv -v -- "$fname" "$newname" 2>>"$ERROR_LOG"; then
        echo "SUCCESS: '$fname' -> '$newname'" >> "$SUCCESS_LOG"
    else
        echo "ERROR: Failed to rename '$fname' to '$newname'" >> "$ERROR_LOG"
    fi
done

echo "Renaming completed."
echo "Successful renames logged in $SUCCESS_LOG"
echo "Failed renames logged in $ERROR_LOG"

read -p "Do you want to open the success log file? (yes/no): " open_answer

if [[ "$open_answer" =~ ^(evet|e|yes|y)$ ]]; then
    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$SUCCESS_LOG"
    elif command -v open >/dev/null 2>&1; then
        open "$SUCCESS_LOG"
    else
        less "$SUCCESS_LOG"
    fi
fi
