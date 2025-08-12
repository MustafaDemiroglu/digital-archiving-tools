#!/usr/bin/env bash

# archive_files.sh
# Simple script to copy all files from a source folder to an "archive" folder.
# Usage: ./archive_files.sh /path/to/source/folder

SOURCE_DIR=$1          # First argument is source directory
ARCHIVE_DIR="./archive"  # Archive folder (inside current folder)

# Check if source directory is given
if [ -z "$SOURCE_DIR" ]; then
  echo "Please specify the source directory. Example:"
  echo "./archive_files.sh /path/to/source"
  exit 1
fi

# Check if source directory exists
if [ ! -d "$SOURCE_DIR" ]; then
  echo "Source directory does not exist: $SOURCE_DIR"
  exit 1
fi

# Create archive folder if not exists
mkdir -p "$ARCHIVE_DIR"

echo "Starting to archive files..."

# Loop over all files in source directory
for file in "$SOURCE_DIR"/*; do
  if [ -f "$file" ]; then              # Check if it is a file
    rsync -avk --progress "$file" "$ARCHIVE_DIR/"        # Copy file to archive folder
    echo "Archived: $(basename "$file")"
  fi
done

echo "Archiving finished. Files saved in $ARCHIVE_DIR"