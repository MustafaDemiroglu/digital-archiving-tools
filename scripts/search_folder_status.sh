#!/bin/bash

###############################################################################
# Script Name : search_folder_status.sh
# Version     : 1.8
# Author      : Mustafa Demiroglu
# Purpose     : 
#   This script checks if the folders listed in a file exist under /media/cepheus.
#   You can choose a file with .csv, .txt, or .list extension.
# Short explanations:
#   The script lets you pick a file with folder names/paths.
#   Only files with .csv, .txt, or .list extensions can be selected.
#   It checks if each folder exists under /media/cepheus.
#   Results are saved to search_result.csv with two columns: folder path and status.
###############################################################################

# Function to remove spaces and special characters from start and end
trim() {
  echo -n "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/\r//g'
}

# If no file name is given, let user select a correct file type
if [[ -z "$1" ]]; then
  echo "No file given. Showing only CSV, TXT, or LIST files in this folder:"
  # Only show files with these extensions (not case-sensitive)
  mapfile -t files < <(find . -maxdepth 1 -type f \( -iname "*.csv" -o -iname "*.txt" -o -iname "*.list" \) -printf "%f\n")
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No CSV, TXT, or LIST files found in this directory."
    exit 1
  fi
  select filename in "${files[@]}"; do
    if [[ -n "$filename" && -f "$filename" ]]; then
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

# Clear any previous result file, so we start fresh
> search_result.csv

# Write the header line to the result file (comma separated)
echo "Folder Path,Status" > search_result.csv

# Read each line in the input file
while IFS= read -r line || [[ -n "$line" ]]; do
  # Remove any unwanted spaces and special characters from the line
  folder_path=$(trim "$line")
  
  # Skip if the line is empty
  if [[ -z "$folder_path" ]]; then
    continue
  fi

  # Full path for the directory
  full_path="/media/cepheus/$folder_path"
  
  # Show which folder is being checked
  echo -ne "\rSearching: $folder_path                                "
  
  # Check if folder exists
  if [[ -d "$full_path" ]]; then
    echo -e "$folder_path;exist" >> search_result.csv
  else
    echo -e "$folder_path,not_exist" >> search_result.csv
  fi

done < "$input_file"

# Print finish message
echo -e "\rSearch complete. Results saved to search_result.csv.       "