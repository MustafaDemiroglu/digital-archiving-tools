#!/bin/bash

# =============================================================================
# SCRIPT: Seperate Dirs / Move and Renumber TIF Files
# =============================================================================
#
# Author: Mustafa Demiroglu
# Organisation: HlaDigiTeam
# License: MIT
#
# DESCRIPTION:
#   This script moves TIF files from a source folder to a target folder and
#   renumbers them sequentially starting from 1. It only processes files that
#   have a number equal to or greater than a specified start number.
#
# HOW IT WORKS:
#   1. Checks if source folder exists and target folder is empty/creatable
#   2. Lists all TIF files in source folder matching the pattern
#   3. Filters files with numbers >= START_NUMBER
#   4. Moves filtered files to target folder
#   5. Renumbers them sequentially starting from 0001
#
# FILE NAMING PATTERN:
#   Source: hhstaw_519--3_nr_<SOURCE_FOLDER>_<NUMBER>.tif
#   Target: hhstaw_519--3_nr_<TARGET_FOLDER>_<NUMBER>.tif
#
# USAGE:
#   ./script.sh <SOURCE_FOLDER> <TARGET_FOLDER> <START_NUMBER>
#
# EXAMPLE:
#   ./script.sh folder1 folder2 50
#   This will move all files from folder1 with numbers >= 0050 to folder2,
#   renumbering them as 0001, 0002, 0003, etc.
#
# =============================================================================

# Check arguments
if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <SOURCE_FOLDER> <TARGET_FOLDER> <START_NUMBER>"
    exit 1
fi

SOURCE_FOLDER=$1
TARGET_FOLDER=$2
START_NUMBER=$3

# Make START_NUMBER 4 digits
START_NUMBER=$(printf "%04d" $START_NUMBER)

# Check if source folder exists
if [ ! -d "$SOURCE_FOLDER" ]; then
    echo "Error: Source folder ($SOURCE_FOLDER) does not exist."
    exit 1
fi

# Check / create target folder
if [ -d "$TARGET_FOLDER" ]; then
    # Folder exists but is it empty?
    if [ "$(ls -A "$TARGET_FOLDER")" ]; then
        echo "Error: Target folder ($TARGET_FOLDER) already exists and is not empty."
        exit 1
    else
        echo "Target folder exists and is empty. Using it."
    fi
else
    mkdir "$TARGET_FOLDER"
fi

# List files
FILES=$(ls ${SOURCE_FOLDER}/hhstaw_519--3_nr_${SOURCE_FOLDER}_*.tif | sort)

# Select files starting from START_NUMBER
FILES_TO_MOVE=$(echo "$FILES" | while read FILE; do
    NUM=$(echo "$FILE" | sed -E 's/.*_([0-9]{4})\.tif/\1/')
    if [ "$NUM" -ge "$START_NUMBER" ]; then
        echo "$FILE"
    fi
done)

# Move selected files and rename with increasing number starting 1
COUNTER=1
for FILE in $FILES_TO_MOVE; do
    NEW_FILE="${TARGET_FOLDER}/hhstaw_519--3_nr_${TARGET_FOLDER}_$(printf "%04d" $COUNTER).tif"
    mv "$FILE" "$NEW_FILE"
    COUNTER=$((COUNTER + 1))
done

echo "File move and renaming completed successfully!"
exit 0
