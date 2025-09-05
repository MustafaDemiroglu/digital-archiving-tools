#!/bin/bash

###############################################################################
# Script Name : search_folder_status.sh
# Version     : 2.0
# Author      : Mustafa Demiroglu
# Purpose     : 
#   This script checks if the folders listed in a file exist under a chosen base path.
#   You can choose a file with .csv, .txt, or .list extension.
#   It collects extended information about existing folders (creation date, file count,
#   file types, and file creation dates).
###############################################################################

# Function to remove spaces and special characters from start and end
trim() {
  echo -n "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/\r//g'
}

# Step 1: Ask user for base path
echo "Please choose the base directory for the search:"
PS3="Enter the number of your choice: "
options=("/media/cepheus" "/media/archive/public/www" "Custom path")
select opt in "${options[@]}"; do
  case $opt in
    "/media/cepheus")
      base_path="/media/cepheus"
      break
      ;;
    "/media/archive/public/www")
      base_path="/media/archive/public/www"
      break
      ;;
    "Custom path")
      read -rp "Enter your custom base path: " base_path
      if [[ ! -d "$base_path" ]]; then
        echo "Path '$base_path' not found. Exiting."
        exit 1
      fi
      break
      ;;
    *)
      echo "Invalid choice. Please try again."
      ;;
  esac
done

# Step 2: If no file name is given, let user select a correct file type
if [[ -z "$1" ]]; then
  echo "No file given. Showing only CSV, TXT, or LIST files in this folder:"
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

# Step 3: Prepare result file
> search_result.csv
echo "Folder Path;Status;Creation Date;File Count;File Types;File Creation Dates" > search_result.csv

# Step 4: Process each line in the input file
while IFS= read -r line || [[ -n "$line" ]]; do
  folder_path=$(trim "$line")

  # Skip empty lines
  if [[ -z "$folder_path" ]]; then
    continue
  fi

  full_path="$base_path/$folder_path"
  echo -ne "\rSearching: $folder_path                                "

  if [[ -d "$full_path" ]]; then
    # Get creation date of the folder
    creation_date=$(stat -c %w "$full_path" 2>/dev/null)
    [[ "$creation_date" == "-" ]] && creation_date=$(stat -c %y "$full_path" | cut -d' ' -f1)

    # Get number of files inside
    file_count=$(find "$full_path" -type f | wc -l)

    # Get file types (extensions, unique, separated by _)
    file_types=$(find "$full_path" -type f -printf "%f\n" | sed -n 's/.*\.//p' | sort -u | tr '\n' '_' | sed 's/_$//')

    # Get file creation dates (unique, separated by _)
    file_dates=$(find "$full_path" -type f -printf "%TY-%Tm-%Td\n" 2>/dev/null | sort -u | tr '\n' '_' | sed 's/_$//')

    echo -e "$folder_path;exist;$creation_date;$file_count;$file_types;$file_dates" >> search_result.csv
  else
    echo -e "$folder_path;not_exist;;;;" >> search_result.csv
  fi
done < "$input_file"

echo -e "\rSearch complete. Results saved to search_result.csv.       "