#!/bin/bash

# This script moves and renames files from a source folder to a target folder.
# It checks if the source and target folders exist, and then moves files
# from the source folder starting from a given file number.
# The files will be renamed in the target folder with the new signature number.

# Get source folder, target folder, and starting file number from the arguments
SOURCE_FOLDER=$1
TARGET_FOLDER=$2
START_NUMBER=$3

# Check if the source folder exists
if [ ! -d "$SOURCE_FOLDER" ]; then
    echo "Error: Source folder ($SOURCE_FOLDER) does not exist."
    exit 1
fi

# Check if the target folder exists
if [ -d "$TARGET_FOLDER" ]; then
    echo "Error: Target folder ($TARGET_FOLDER) already exists."
    exit 1
else
    mkdir "$TARGET_FOLDER"  # If the target folder doesn't exist, create it
fi

# Get the list of files in the source folder and sort them
FILES=$(ls ${SOURCE_FOLDER}/hhstaw_519--3_nr_${SOURCE_FOLDER}_*.tif | sort)

# Select the files starting from the specified number
FILES_TO_MOVE=$(echo "$FILES" | grep -E "_${START_NUMBER}.tif" | sort)

# Move and rename files
COUNTER=1  # Start the file number from 1
for FILE in $FILES_TO_MOVE; do
    # Create the new filename with the correct sequence number
    NEW_FILE="${TARGET_FOLDER}/hhstaw_519--3_nr_${TARGET_FOLDER}_$(printf "%04d" $COUNTER).tif"

    # Move the file to the target folder
    mv "$FILE" "$NEW_FILE"

    COUNTER=$((COUNTER + 1))  # Increment the counter for the next file
done

# Print success message after all files have been moved and renamed
echo "File move and renaming completed successfully!"

exit 0
