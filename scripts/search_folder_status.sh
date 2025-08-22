#!/bin/bash

###############################################################################
# Script Name : search_folder_status.sh
# Version     : 1.2
# Author      : Mustafa Demiroglu
# Purpose     : 
# 				This script checks if folders listed in a file exist under /media/cepheus
# 				If no file is given, it lets you choose a file from the current directory
# 				It supports CSV, TXT or any file with folder paths separated by comma, space, semicolon, or newlines               
#
# Tested Shells: bash 4+ (Linux, Git Bash on Windows)
###############################################################################

# Function to trim whitespace
trim() {
  echo "$1" | xargs
}

# Ask for the file if not given as argument
if [[ -z "$1" ]]; then
  echo "No file given. Listing files in this folder:"
  # List files only (ignore folders)
  select filename in *; do
    if [[ -f "$filename" ]]; then
      input_file="$filename"
      break
    else
      echo "Please choose a valid file!"
    fi
  done
else
  input_file="$1"
  if [[ ! -f "$input_file" ]]; then
    echo "File '$input_file' not found. Please check the filename and try again."
    exit 1
  fi
fi

# Prepare result file
echo "Folder Path, Status" > search_result.csv

# Read lines, split on commas, spaces or semicolons, and search for each path
while IFS= read -r line || [[ -n "$line" ]]; do
  # Split line by comma, space, or semicolon
  IFS=$' ,;' read -ra paths <<< "$line"
  for raw_path in "${paths[@]}"; do
    folder_path=$(trim "$raw_path")
    # Skip if empty
    if [[ -z "$folder_path" ]]; then
      continue
    fi
    full_path="/media/cepheus/$folder_path"
    # Show progress in terminal (no newline)
    echo -ne "\rSearching: $folder_path                                "
    if [[ -d "$full_path" ]]; then
      echo "$folder_path, existiert" >> search_result.csv
    else
      echo "$folder_path, nicht_existiert" >> search_result.csv
    fi
  done
done < "$input_file"

# Print done message and clear progress line
echo -e "\rSearch complete. Results saved to search_result.csv.       "