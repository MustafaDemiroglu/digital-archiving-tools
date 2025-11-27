#!/bin/bash

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
