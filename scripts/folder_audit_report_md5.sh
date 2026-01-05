#!/bin/bash

###############################################################################
# Script Name : folder_audit_report_md5.sh
# Version : 3.0
# Author: Mustafa Demiroglu
#
# Purpose     : 
#   This script performs an audit of the lowest-level folders
#   inside a given directory structure. It automatically checks both
#   `/media/cepheus` and `/media/archive/public/www` to see if the folders exist,
#   and generates a CSV report with detailed metadata for comparison. You should execute in kitodo-pilot vm.
#
# What it does:
#   1. Finds all lowest-level (leaf) folders inside the working directory.
#   2. For each folder, collects metadata (creation date, file count, file types, file creation dates).
#   3. Checks whether the same folder exists in both `/media/cepheus or /media/cepheus/secure` and `/media/archive/public/www`.
#   4. Records detailed status for each location and adds an evaluation column with explanations about potential differences.
#
# Output:
#   result_folder_audit_report_<DATE>.csv
###############################################################################

# --- Functions ---

# Trim spaces, remove carriage returns, and drop leading ./
trim() {
  echo -n "$1" | sed 's#^\./##;s/^[[:space:]]*//;s/[[:space:]]*$//;s/\r//g'
}

# Get possible Cepheus paths (secure / non-secure tolerant)
get_cepheus_paths() {
  local folder="$1"
  local clean="$folder"

  # Clean path if starts with secure
  clean="${clean#secure/}"

  echo "/media/cepheus/$clean"
  echo "/media/cepheus/secure/$clean"
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

# Compare MD5 of all files in two folders (content-based comparison)
compare_md5() {
  local folder_src="$1"
  local folder_dst="$2"

  total_src_files=0
  total_dst_files=0
  same_md5_cnt=0
  diff_md5_cnt=0
  same_md5_samples=""

  # Build hash -> paths mapping for destination
  declare -A dst_by_hash
  # Also track number of files in destination
  while IFS= read -r -d '' f; do
    rel=${f#./}
	# compute hash with md5sum; ignore errors silently
    h=$(md5sum "$folder_dst/$rel" 2>/dev/null | awk '{print $1}')
    if [[ -n "$h" ]]; then
      if [[ -z "${dst_by_hash[$h]}" ]]; then
        dst_by_hash[$h]="$rel"
      else
        dst_by_hash[$h]="${dst_by_hash[$h]}|$rel"
      fi
      total_dst_files=$((total_dst_files+1))
    fi
  done < <(cd "$folder_dst" 2>/dev/null && find . -type f -print0)

  # For each src file compute its hash and check if that hash exists in dst_by_hash
  # Count per-file matches (a source file counts as matched if its hash is present in dst)
  while IFS= read -r -d '' f; do
    rel=${f#./}
    total_src_files=$((total_src_files+1))
    h=$(md5sum "$folder_src/$rel" 2>/dev/null | awk '{print $1}')
    if [[ -n "$h" && -n "${dst_by_hash[$h]}" ]]; then
      same_md5_cnt=$((same_md5_cnt+1))
	  # create a sample line: "src/rel -> dstpath1|dstpath2"
      sample_line="$rel -> ${dst_by_hash[$h]}"
	  # limit the number of sample lines to avoid extremely long messages
      if [[ $(echo -n "$same_md5_samples" | wc -l) -lt 25 ]]; then
        same_md5_samples+="${sample_line}"$'\n'
      fi
    else
      diff_md5_cnt=$((diff_md5_cnt+1))
    fi
  done < <(cd "$folder_src" 2>/dev/null && find . -type f -print0)

  # if totals equal and no diffs and counts are equal and also file counts equal -> return 0 (identical)
  if (( total_src_files == total_dst_files && diff_md5_cnt == 0 )); then
    return 0
  else
    return 1
  fi
}

# --- Compare metadata sets without creation date ---
# Strip first field (creation date) and last field (file creation dates) before comparison
strip_dates_from_metadata() {
  echo "$1" | cut -d';' -f2-3
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

  # --- CASE 1 - KRITISCH: both secure + non-secure
  if [[ "$status_cepheus" == "exist_both" ]]; then
    echo "KRITISCH. Ordner ist sowohl im secure- als auch im non-secure-Bereich von Cepheus vorhanden. Dublettenrisiko. Manuelle Pruefung erforderlich."
    return
  fi
  
  # compare metadata without creation dates (both folder and file dates)
  local meta_cepheus_nd
  local meta_self_nd
  meta_cepheus_nd=$(strip_dates_from_metadata "$meta_cepheus")
  meta_self_nd=$(strip_dates_from_metadata "$meta_self")
  
  # Initialize md5 comparison variables (will be set by compare_md5 if called)
  total_src_files=0
  total_dst_files=0
  same_md5_cnt=0
  diff_md5_cnt=0
  same_md5_samples=""
  
  # Evaluation process
  # --- CASE 2: Cepheus does not exist ---
  if [[ "$status_cepheus" == "not_exist" ]]; then
    if [[ "$status_nutzung" == "not_exist" ]]; then
      echo "Uploadbereit. weder in Cepheus noch in NetApp vorhanden"
    else
      echo "Pruefen. Ordner nur in NutzungDigis vorhanden. vielleicht manuell erstellt"
    fi
    return
  fi
  
  # --- CASE 3: Cepheus exists (main check starts here) ---
  # Always perform md5 comparison for all Case 2 situations
  compare_md5 "$folder" "$full_path_cepheus"
  cmp_result=$?
  
  # Build md5 comparison note
  local md5_note
  if [[ $cmp_result -eq 0 ]]; then
    md5_note="md5 geprueft und alle Dateien stimmen ueberein."
  else
    md5_note="Inhaltsvergleich zeigt Unterschiede."
    md5_note+="; (${same_md5_cnt} von ${total_src_files} Quelldatei/en sind in Cepheus inhaltlich vorhanden; ${diff_md5_cnt} Datei/en unterscheiden sich oder fehlen)."
    # If there are samples, include them (limit to first 10 samples)
    if [[ -n "$same_md5_samples" ]]; then
      md5_note+="; Ubereinstimmungen (src -> dst): "
      local sample_snippet
      sample_snippet=$(echo -n "$same_md5_samples" | sed -n '1,10p' | tr '\n' ';' | sed 's/;$/./')
      md5_note+=";${sample_snippet}"
    fi
  fi
  
  # Now build the evaluation note based on metadata comparison
  if [[ "$meta_cepheus_nd" != "$meta_self_nd" ]]; then
    # Metadata differ
    if [[ "$status_nutzung" == "not_exist" ]]; then
      echo "Pruefen. Ordner in Cepheus vorhanden aber Digitalisate sind nicht identisch. es gibt keine Nutzungskopie; ${md5_note}"
    else
      echo "Pruefen. Digitalisate im Cepheus und NutzungDigis in NetApp vorhanden. Unterschiede zwischen Cepheus und neuer Lieferung (Dateien/Typen weichen ab). Entscheidung erforderlich; ${md5_note}"
    fi
  else
    # Metadata identical (without dates)
    if [[ $cmp_result -eq 0 ]]; then
      echo "identisch. ${md5_note} Keine Migration"
    else
      echo "Pruefen. Metadaten gleich, jedoch; ${md5_note}"
    fi
  fi
}

# --- Main script ---

timestamp=$(date +%Y-%m-%d)
output_file="result_folder_audit_report_${timestamp}.csv"

# Write header
echo "Folder Path;Creation Date;File Count;File Types;File Creation Dates;Status (Cepheus);Creation Date (Cepheus);File Count (Cepheus);File Types (Cepheus);File Creation Dates (Cepheus);Status (Nutzung);Creation Date (Nutzung);File Count (Nutzung);File Types (Nutzung);File Creation Dates (Nutzung);Evaluation" > "$output_file"

# Find all lowest-level folders
echo "Finding and listing all lowest-level folders... It can take sometime..."
mapfile -t folders < <(find . -type d ! -exec sh -c 'find "$1" -mindepth 1 -type d | grep -q .' sh {} \; -print | sort)
total_folders=${#folders[@]}
processed=0

# Reserve 5 lines (one for each message)
echo "Check process started"
echo "Checking if folders already exist in Cepheus or NetApp"
echo "Collecting metadata & evaluating differences"
echo "Status: running..."
echo "Progress: 0%"

# Process each folder
for folder in "${folders[@]}"; do
  folder_clean=$(trim "$folder")

  # Update progress for finding folders
  processed=$((processed + 1))
  progress=$((processed * 100 / total_folders))

  # Move cursor up 1 line and overwrite
  tput cuu 1
  printf "Progress: %d%% complete\n" "$progress"

  # Metadata self
  meta_self=$(get_metadata "$folder_clean")

  # Metadata Cepheus
  cepheus_matches=()
  while IFS= read -r p; do
    [[ -d "$p" ]] && cepheus_matches+=("$p")
  done < <(get_cepheus_paths "$folder_clean")

  case "${#cepheus_matches[@]}" in
    0)
      status_cepheus="not_exist"
      meta_cepheus=";;;"
      full_path_cepheus=""
      ;;
    1)
      full_path_cepheus="${cepheus_matches[0]}"
      meta_cepheus=$(get_metadata "$full_path_cepheus")
      [[ "$full_path_cepheus" == */secure/* ]] && \
        status_cepheus="exist_secure" || status_cepheus="exist_non_secure"
      ;;
    *)
      status_cepheus="exist_both"
      meta_cepheus=$(get_metadata "${cepheus_matches[0]}")
      full_path_cepheus="${cepheus_matches[0]}"
      ;;
  esac

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
done

echo "Status: Audit complete. Results saved to:"
echo "$output_file"