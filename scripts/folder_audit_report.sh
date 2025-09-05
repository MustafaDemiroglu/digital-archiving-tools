#!/bin/bash

###############################################################################
# Script Name : folder_audit_report.sh
# Version     : 1.0
# Author      : Mustafa Demiroglu
# Purpose     : 
#   This script performs a data stewardship audit of the lowest-level folders
#   inside a given directory structure. It automatically checks both
#   `/media/cepheus` and `/media/archive/public/www` to see if the folders exist,
#   and generates a CSV report with detailed metadata for comparison.
#
# What it does:
#   1. Finds all lowest-level (leaf) folders inside the working directory.
#   2. For each folder, collects metadata (creation date, file count,
#      file types, file creation dates).
#   3. Checks whether the same folder exists in both `/media/cepheus`
#      and `/media/archive/public/www`.
#   4. Records detailed status for each location.
#   5. Adds an evaluation column with explanations about potential differences.
#
# Output:
#   result_folder_audit_report_<DATE>.csv
#
# Compatibility:
#   Written in portable Bash, tested on Linux/WSL. Uses only standard commands
#   (find, stat, wc, sort, uniq, sed, tr).
###############################################################################

# --- Functions ---

# Trim spaces and remove carriage returns
trim() {
  echo -n "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/\r//g'
}

# Collect metadata for a given folder path
# Returns: creation_date;file_count;file_types;file_dates
get_metadata() {
  local folder="$1"

  if [[ ! -d "$folder" ]]; then
    echo ";;;"; return
  fi

  # Creation date of folder
  local creation_date
  creation_date=$(stat -c %w "$folder" 2>/dev/null)
  [[ "$creation_date" == "-" ]] && creation_date=$(stat -c %y "$folder" | cut -d' ' -f1)

  # File count
  local file_count
  file_count=$(find "$folder" -type f | wc -l)

  # File types (extensions, unique, joined with "_")
  local file_types
  file_types=$(find "$folder" -type f -printf "%f\n" | sed -n 's/.*\.//p' | sort -u | tr '\n' '_' | sed 's/_$//')

  # File creation dates (unique, joined with "_")
  local file_dates
  file_dates=$(find "$folder" -type f -printf "%TY-%Tm-%Td\n" 2>/dev/null | sort -u | tr '\n' '_' | sed 's/_$//')

  echo "$creation_date;$file_count;$file_types;$file_dates"
}

# Compare metadata sets between Cepheus and Nutzung Digis
evaluate() {
  local status_cepheus="$1"
  local meta_cepheus="$2"
  local status_nutzung="$3"
  local meta_nutzung="$4"

  if [[ "$status_cepheus" == "not_exist" && "$status_nutzung" == "not_exist" ]]; then
    echo "Hochladen bereit, im cepheuss nichts zu finden"
  elif [[ "$status_cepheus" == "exist" && "$status_nutzung" == "not_exist" ]]; then
    echo "Nur in Cepheus vorhanden"
  elif [[ "$status_cepheus" == "not_exist" && "$status_nutzung" == "exist" ]]; then
    echo "Nutzung Digis wurden vielleicht manuell erstellt, in Cepheus Digitalisate nicht vorhanden"
  elif [[ "$status_cepheus" == "exist" && "$status_nutzung" == "exist" ]]; then
    if [[ "$meta_cepheus" == "$meta_nutzung" ]]; then
      echo "Daten stimmen überein, Digitalisate wurde schon vorher geliefert"
    else
      echo "Unterschiede zwischen Cepheus und Nutzung Digis (Dateien/Typen/Zeiten weichen ab)"
    fi
  else
    echo "Unbekannter Status"
  fi
}

# --- Main script ---

# Output file with timestamp
timestamp=$(date +%Y-%m-%d)
output_file="result_folder_audit_report_${timestamp}.csv"

# Write header
echo "Folder Path;Creation Date;File Count;File Types;File Creation Dates;Status (Digitalisate);Creation Date (Cepheus);File Count (Cepheus);File Types (Cepheus);File Creation Dates (Cepheus);Status (Nutzung_Digis);Creation Date (Nutzung);File Count (Nutzung);File Types (Nutzung);File Creation Dates (Nutzung);Evaluation" > "$output_file"

# Step 1: Find all lowest-level folders in current directory
echo "Finding all lowest-level folders..."
mapfile -t folders < <(find . -type d ! -exec sh -c 'find "$1" -mindepth 1 -type d | grep -q .' sh {} \; -print | sort)

# Step 2: Process each folder
for folder in "${folders[@]}"; do
  folder_clean=$(trim "$folder")

  # Metadata for the folder itself
  meta_self=$(get_metadata "$folder_clean")
  IFS=";" read -r self_creation self_count self_types self_dates <<< "$meta_self"

  # Metadata for /media/cepheus
  full_path_cepheus="/media/cepheus/$folder_clean"
  if [[ -d "$full_path_cepheus" ]]; then
    status_cepheus="exist"
    meta_cepheus=$(get_metadata "$full_path_cepheus")
  else
    status_cepheus="not_exist"
    meta_cepheus=";;;;"
  fi

  # Metadata for /media/archive/public/www
  full_path_nutzung="/media/archive/public/www/$folder_clean"
  if [[ -d "$full_path_nutzung" ]]; then
    status_nutzung="exist"
    meta_nutzung=$(get_metadata "$full_path_nutzung")
  else
    status_nutzung="not_exist"
    meta_nutzung=";;;;"
  fi

  # Evaluate differences
  eval_text=$(evaluate "$status_cepheus" "$meta_cepheus" "$status_nutzung" "$meta_nutzung")

  # Write row to CSV
  echo "$folder_clean;$self_creation;$self_count;$self_types;$self_dates;$status_cepheus;${meta_cepheus};$status_nutzung;${meta_nutzung};$eval_text" >> "$output_file"
done

echo "Audit complete. Results saved to $output_file"