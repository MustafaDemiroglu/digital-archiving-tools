#!/usr/bin/env bash

############################################
# Script Name: path_cleaner_and_formatter.sh
# Author: Mustafa Demiroglu
# Version: 3.2
# License: MIT
#
# Description:
#   Lists CSV files in the current working directory,
#   asks the user which one to process,
#   cleans paths by:
#       1. Removing '/media/cepheus/' prefix
#       2. Removing trailing filename
#       3. Keeping only the middle directory structure
#       4. Removing duplicate directory entries
#   Saves result into a new file with '_done.csv' suffix.
#############################################

# --- Step 1: List CSV files in current directory ---
shopt -s nullglob
csv_files=(*.csv)

if [[ ${#csv_files[@]} -eq 0 ]]; then
    echo "No CSV files found in the current directory."
    exit 1
fi

echo "CSV files found in this directory:"
for i in "${!csv_files[@]}"; do
    printf "%d) %s\n" $((i+1)) "${csv_files[$i]}"
done

# --- Step 2: Ask user to choose a file ---
read -p "Enter the number of the file you want to process: " choice

# Validate choice
if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#csv_files[@]} )); then
    echo "Invalid selection."
    exit 1
fi

input_file="${csv_files[$((choice-1))]}"
output_file="${input_file%.*}_done.csv"

echo "Processing: $input_file -> $output_file"

# --- Step 3: Process file and remove duplicates ---
awk -F'[ ,;]+' '
{
    for (i=1; i<=NF; i++) {
        segment=$i
        gsub("^/media/cepheus/", "", segment)  # Remove prefix
        sub("/[^/]+$", "", segment)            # Remove trailing filename
        if (length(segment) > 0) {
            print segment
        }
    }
}' "$input_file" | sort -u > "$output_file"

echo "Done. Cleaned and deduplicated data saved to: $output_file"