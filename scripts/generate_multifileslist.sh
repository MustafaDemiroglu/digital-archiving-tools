#!/bin/bash

###############################################################################
# Script		: generate_multifileslist.sh
# Version		: 2.2
# Author		: Mustafa Demiroglu
# Organisation	: HlaDigiTeam
#
# Description:
#   This script reads a list of relative directory paths from /tmp/multifiles.list
#   and generates a list (/tmp/generierung.list) of files.
#
#   Default mode:
#     - Lists ALL files under given directories
#	  - ./generate_multifileslist.sh	
#
#   Optional profile:
#     --only_first_images
#     - Finds all leaf (deepest) directories
#     - Takes only the first image (natural sort) from each leaf directory
#	  - ./generate_multifileslist.sh --only_first_images
#
# Output:
#   /tmp/generierung.list
###############################################################################

# Clear output file
> /tmp/generierung.list

LIST_FILE="/tmp/multifiles.list"
BASE_DIR="/media/cepheus"

# Optional profile flag
ONLY_FIRST_IMAGES=false
if [[ "$1" == "--only_first_images" ]]; then
    ONLY_FIRST_IMAGES=true
fi

# Check input list
if [[ ! -f "$LIST_FILE" ]]; then
    echo "Directory list file ($LIST_FILE) not found!"
    exit 1
fi

while IFS= read -r LINE || [[ -n "$LINE" ]]; do
    [[ -z "$LINE" ]] && continue

    for REL_DIR in $LINE; do
        [[ -z "$REL_DIR" ]] && continue

        # Normalize path
        REL_DIR="${REL_DIR%/}"
        REL_DIR="${REL_DIR%/\*}"
        REL_DIR="${REL_DIR#./}"

        if [[ "$REL_DIR" = /* ]]; then
            ABS_DIR="$REL_DIR"
        else
            ABS_DIR="$BASE_DIR/$REL_DIR"
        fi

        if [[ ! -d "$ABS_DIR" ]]; then
            echo "Warning: Directory not found -> $ABS_DIR" >&2
            continue
        fi

        echo "Success: $ABS_DIR"

        if [[ "$ONLY_FIRST_IMAGES" == false ]]; then
            # Default behavior: list all files
            find "$ABS_DIR" -type f >> /tmp/generierung.list
        else
            # --only_first_images behavior
            find "$ABS_DIR" -type d | while read -r DIR; do
				# Check if directory has NO subdirectories (leaf directory)
				if [[ -z "$(find "$DIR" -mindepth 1 -type d -print -quit)" ]]; then

					# Take first image in natural sort order
					FIRST_IMAGE=$(find "$DIR" -maxdepth 1 -type f \
					| grep -iE '.*\.(jpg|jpeg|tif|tiff|png)$' \
					| sort -V \
					| head -n 1)

					if [[ -n "$FIRST_IMAGE" ]]; then
						echo "$FIRST_IMAGE" >> /tmp/generierung.list
					fi
				fi
			done
        fi
    done
done < "$LIST_FILE"

echo "List successfully created: /tmp/generierung.list"