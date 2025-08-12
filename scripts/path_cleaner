#!/bin/bash

# 1. Step: Show CSV files in the current directory and allow the user to choose one
echo "Finding CSV files in the current directory..."
csv_files=(*.csv)

if [ ${#csv_files[@]} -eq 0 ]; then
  echo "No CSV files found in the current directory."
  exit 1
fi

echo "Please select a CSV file to process:"
select file in "${csv_files[@]}"; do
  if [[ -n "$file" ]]; then
    echo "You selected $file"
    break
  else
    echo "Invalid selection, try again."
  fi
done

# 2. Step: Process each line in the selected CSV file
output_file="processed_output.csv"
> "$output_file"  # Create/clear the output file

while IFS= read -r line; do
  # Example line: Heiratsnebenregister_hstam_912_nr_9317_1938|Heiratsnebenregister|Weilmünster, Oberlahnkreis, Hessen-Nassau, Freistaat Preußen, Deutschland|1 Jul–31 Dec 1938|69
  # Extracting the desired part of the string (starting with "hstam" and ending before "_nr")

  if [[ "$line" =~ hstam_([0-9]+)_nr_([0-9]+)_([0-9]+) ]]; then
    # Capture the components we need (bestand_nr and archiv_nr)
    bestand_nr="${BASH_REMATCH[1]}"
    archiv_nr="${BASH_REMATCH[2]}"

    # Create the new formatted path
    new_filename="hstam/${bestand_nr}/${archiv_nr}"

    # Write the new filename to the output file
    echo "$new_filename" >> "$output_file"
  fi
done < "$file"

# 3. Step: Remove duplicates from the output file
sort -u "$output_file" -o "$output_file"

echo "Process completed! The resulting file with unique entries is saved as '$output_file'."

