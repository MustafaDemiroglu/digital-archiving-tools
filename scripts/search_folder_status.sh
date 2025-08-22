#!/bin/bash

###############################################################################
# Script Name : search_folder_status.sh
# Version     : 1.4
# Author      : Mustafa Demiroglu
# Purpose     : 
#   This script checks if the folders listed in a file exist under /media/cepheus.
#   You can use CSV, TXT or any file with folder paths separated by comma, space, semicolon, or newlines.
#   If no file is given, it lets you choose a file from the current directory (shows ONLY regular files).
###############################################################################

# Trim function
trim() {
  echo -n "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/\r//g'
}

# If no file is given as an argument, let the user select one (ONLY regular files, not directories)
if [[ -z "$1" ]]; then
  echo "No file given. Listing only files in this folder:"
  mapfile -t files < <(find . -maxdepth 1 -type f -printf "%f\n")
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No regular files found in this directory."
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

# Create the result file and write the header (tab separated: real CSV)
echo -e "Folder Path\tStatus" > search_result.csv

while IFS= read -r line || [[ -n "$line" ]]; do
  IFS=$' ,;' read -ra paths <<< "$line"
  for raw_path in "${paths[@]}"; do
    folder_path=$(trim "$raw_path")
    if [[ -z "$folder_path" ]]; then
      continue
    fi
    full_path="/media/cepheus/$folder_path"
    echo -ne "\rSearching: $folder_path                                "
    if [[ -d "$full_path" ]]; then
      echo -e "$folder_path\texist" >> search_result.csv
    else
      echo -e "$folder_path\tnot_exist" >> search_result.csv
    fi
  done
done < "$input_file"

echo -e "\rSearch complete. Results saved to search_result.csv.       "