#!/bin/bash

###############################################################################
# Script Name : folder_audit_report.sh
# Version     : 3.1
# Author      : Mustafa Demiroglu
# Purpose     : 
#   This script performs a data stewardship audit of the lowest-level folders
#   inside a given directory structure. It automatically checks both
#   `/media/cepheus` and `/media/archive/public/www` to see if the folders exist,
#   and generates a CSV report with detailed metadata for comparison. You should execute in kitodo-pilot vm.
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

# Trim spaces, remove carriage returns, and drop leading ./
trim() {
  echo -n "$1" | sed 's#^\./##;s/^[[:space:]]*//;s/[[:space:]]*$//;s/\r//g'
}

# Collect metadata for a given folder path
# Returns: "creation_date;file_count;file_types;file_dates"
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

  # File types
  local file_types
  file_types=$(find "$folder" -type f -printf "%f\n" | sed -n 's/.*\.//p' | sort -u | tr '\n' '_' | sed 's/_$//')

  # File creation dates (wrapped in quotes to enforce left align in Excel)
  local file_dates
  file_dates=$(find "$folder" -type f -printf "%TY-%Tm-%Td\n" 2>/dev/null | sort -u | tr '\n' '_' | sed 's/_$//')
  [[ -n "$file_dates" ]] && file_dates="\"$file_dates\""

  echo "$creation_date;$file_count;$file_types;$file_dates"
}

# Compare md5sums of all files in two folders
compare_md5() {
  local folder1="$1"
  local folder2="$2"

  diff -q <(find "$folder1" -type f -exec md5sum {} + | sort) \
          <(find "$folder2" -type f -exec md5sum {} + | sort) >/dev/null
  return $?
}

# --- Compare metadata sets without creation date ---
# Strip first field (creation date) before comparison
strip_creation_date() {
  echo "$1" | cut -d';' -f2-
}

# Evaluate differences
evaluate() {
  local folder="$1"
  local status_cepheus="$2"
  local meta_cepheus="$3"
  local status_nutzung="$4"
  local meta_nutzung="$5"
  local meta_self="$6"
  local full_path_cepheus="$7"

  # compare metadata without creation date
  local meta_cepheus_nc
  local meta_self_nc
  meta_cepheus_nc=$(strip_creation_date "$meta_cepheus")
  meta_self_nc=$(strip_creation_date "$meta_self")

  if [[ "$status_cepheus" == "not_exist" && "$status_nutzung" == "not_exist" ]]; then
    echo "Bereit für Upload – weder in Cepheus noch in NetApp vorhanden"
  elif [[ "$status_cepheus" == "exist" && "$status_nutzung" == "not_exist" ]]; then
    echo "Digitalisate in Cepheus vorhanden, keine Nutzungskopie"
  elif [[ "$status_cepheus" == "not_exist" && "$status_nutzung" == "exist" ]]; then
    echo "Nutzungdigis vorhanden aber Digitalisate nicht – evtl. manuell erstellt"
  elif [[ "$status_cepheus" == "exist" && "$status_nutzung" == "exist" ]]; then
    if [[ "$meta_cepheus_nc" == "$meta_self_nc" ]]; then
      if compare_md5 "$folder" "$full_path_cepheus"; then
        echo "Metadaten (ohne Ordnerdatum) stimmen überein. MD5 geprüft – identisch. Keine Migration nötig."
      else
        echo "Metadaten (ohne Ordnerdatum) gleich, aber Dateien unterscheiden sich (MD5 Abweichungen). Bitte prüfen."
      fi
    else
      echo "Unterschiede zwischen Cepheus und neuer Lieferung (Dateien/Typen/Zeiten weichen ab). Entscheidung erforderlich."
    fi
  else
    echo "Unbekannter Status – bitte manuell prüfen"
  fi
}

# --- Main script ---

timestamp=$(date +%Y-%m-%d)
output_file="result_folder_audit_report_${timestamp}.csv"

# Write header
echo "Folder Path;Creation Date;File Count;File Types;File Creation Dates;Status (Cepheus);Creation Date (Cepheus);File Count (Cepheus);File Types (Cepheus);File Creation Dates (Cepheus);Status (Nutzung);Creation Date (Nutzung);File Count (Nutzung);File Types (Nutzung);File Creation Dates (Nutzung);Evaluation" > "$output_file"

# Find all lowest-level folders
echo "Finding all lowest-level folders..."
find . -type d ! -exec sh -c 'find "$1" -mindepth 1 -type d | grep -q .' sh {} \; -print | sort > /tmp/folders_list.txt

total=$(wc -l < /tmp/folders_list.txt)
echo "Total folders found: $total"

mapfile -t folders < /tmp/folders_list.txt

# Process each folder
for folder in "${folders[@]}"; do
  ((counter++))
  folder_clean=$(trim "$folder")

  # Metadata self
  meta_self=$(get_metadata "$folder_clean")
  IFS=";" read -r self_creation self_count self_types self_dates <<< "$meta_self"

  # Metadata Cepheus
  full_path_cepheus="/media/cepheus/$folder_clean"
  if [[ -d "$full_path_cepheus" ]]; then
    status_cepheus="exist"
    meta_cepheus=$(get_metadata "$full_path_cepheus")
  else
    status_cepheus="not_exist"
    meta_cepheus=";;;"
  fi

  # Metadata Nutzung
  full_path_nutzung="/media/archive/public/www/$folder_clean"
  if [[ -d "$full_path_nutzung" ]]; then
    status_nutzung="exist"
    meta_nutzung=$(get_metadata "$full_path_nutzung")
  else
    status_nutzung="not_exist"
    meta_nutzung=";;;"
  fi

  # Evaluation
  eval_text=$(evaluate "$folder_clean" "$status_cepheus" "$meta_cepheus" "$status_nutzung" "$meta_nutzung" "$meta_self" "$full_path_cepheus")

  # Write row
  echo "$folder_clean;${meta_self};$status_cepheus;${meta_cepheus};$status_nutzung;${meta_nutzung};$eval_text" >> "$output_file"

  # Show progress every 10 folders
  if (( counter % 10 == 0 )); then
    echo "Processed $counter / $total folders..."
  fi
done

echo "Audit complete. Results saved to $output_file"