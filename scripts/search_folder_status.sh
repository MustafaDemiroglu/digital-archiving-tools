#!/bin/bash

###############################################################################
# Script Name : search_folder_status.sh
# Version     : 1.3
# Author      : Mustafa Demiroglu
# Purpose     : 
#   This script checks if the folders listed in a file exist under /media/cepheus.
#   You can use CSV, TXT or any file with folder paths separated by comma, space, semicolon, or newlines.
#   If no file is given, it lets you choose a file from the current directory.
###############################################################################

# This function removes spaces and special characters from the start and end of the text
trim() {
  echo -n "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/\r//g'
}

# If no file is given as an argument, let the user select one
if [[ -z "$1" ]]; then
  echo "No file given. Listing files in this folder:"
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

# Create the result file and write the header
echo "Folder Path, Status" > search_result.csv

# Read the input file line by line
while IFS= read -r line || [[ -n "$line" ]]; do
  # Split the line by comma, space or semicolon
  IFS=$' ,;' read -ra paths <<< "$line"
  for raw_path in "${paths[@]}"; do
    folder_path=$(trim "$raw_path")
    # If the folder path is empty, skip
    if [[ -z "$folder_path" ]]; then
      continue
    fi
    full_path="/media/cepheus/$folder_path"
    # Show progress in the terminal (no new line)
    echo -ne "\rSearching: $folder_path                                "
    # Check if directory exists
    if [[ -d "$full_path" ]]; then
      echo "$folder_path, exist" >> search_result.csv
    else
      echo "$folder_path, not_exist" >> search_result.csv
    fi
  done
done < "$input_file"

# Show done message and clear line
echo -e "\rSearch complete. Results saved to search_result.csv.       "