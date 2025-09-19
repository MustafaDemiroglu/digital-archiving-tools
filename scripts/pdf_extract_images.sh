#!/bin/bash
###############################################################################
# Script Name: pdf_extract_images.sh
# Version 5.1
# Author : Mustafa Demiroglu
#
# Description:
#   This script extracts each page from PDF files into separate images using 'pdfimages'.
#   It supports both TIFF (.tif) and JPEG (.jpg).
#   The script is designed to run on Linux, macOS, or WSL (Windows Subsystem).
#   Concurrency lock prevents multiple instances.
#
# How it works:
#   1. If you do not provide a path, it works in the current folder and subfolders.
#   2. You can choose the output format (tif or jpg). If not provided, the script asks you.
#   3. Output images are named like: haus_bestand_nr_stück_0001.tif / 0001.jpg(based on folder hierarchy)
#      If not enough folder depth → fallback: pdfname_0001.tif
#	   If a folder contains >1 PDF, always use pdfname_0001.ext
#   4. After extraction, checks if number of images = number of PDF pages.
#      - If mismatch → cleanup images, PDF stays in place, error logged.
#      - If equal → PDF moved to "processed_pdfs".
#   5. A log file is created with results and errors.
#
# Requirements:
#   - ImageMagick (for 'pdfimages')
#   - pdfinfo (from poppler-utils package, to count PDF pages)
#
# Example usage:
#   ./pdf_extract_images.sh                # process PDFs in current dir
#   ./pdf_extract_images.sh /path/to/data  # process PDFs in given folder
#   ./pdf_extract_images.sh /data jpg      # extract as jpg instead of tif
###############################################################################

set -euo pipefail

# --- Setup ---
WORKDIR="${1:-$(pwd)}"    # Path to work on, default = current dir
OUTFMT="${2:-}"               # Desired image format (tif or jpg)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOGFILE="$WORKDIR/log_pdf_extract_${TIMESTAMP}.txt"
ERRFILE="$WORKDIR/error_pdf_extract_${TIMESTAMP}.txt"
TMPPDFDIR="processed_pdfs"
LOCKFILE="/tmp/pdf_extract.lock"

# --- Acquire main lock ---
exec 200>"$LOCKFILE"
flock -n 200 || { echo "Another instance is running. Exiting." | tee -a "$ERRFILE"; exit 1; }

# --- Ask for format if not provided ---
if [[ -z "$OUTFMT" ]]; then
  read -p "Which output format do you want (tif/jpg/all)? " OUTFMT
fi
OUTFMT=$(echo "$OUTFMT" | tr '[:upper:]' '[:lower:]')

if [[ "$OUTFMT" != "tif" && "$OUTFMT" != "jpg" && "$OUTFMT" != "all" ]]; then
  echo "Error: output format must be 'tif' or 'jpg' or 'all'" | tee -a "$ERRFILE"
  exit 1
fi

# --- Create processed_pdfs directory and Clear log files from previous runs ---
mkdir -p "$WORKDIR/$TMPPDFDIR"
: > "$LOGFILE"
: > "$ERRFILE"

echo "Starting PDF extraction in: $WORKDIR" | tee -a "$LOGFILE"
echo "Output format: $OUTFMT" | tee -a "$LOGFILE"
echo "Log file: $LOGFILE" | tee -a "$LOGFILE"
echo "Error file: $ERRFILE" | tee -a "$LOGFILE"
echo "Running in sequential mode (one PDF at a time). It can take a while to process all PDFs" | tee -a "$LOGFILE"

# --- Process PDF ---
process_pdf() {
  local pdf="$1"
  local base=$(basename "$pdf" .pdf)
  local dir=$(dirname "$pdf")
  
  echo "Processing: $pdf" | tee -a "$LOGFILE"

  # Count pages
  local pages
  if ! pages=$(pdfinfo "$pdf" 2>/dev/null | awk '/Pages:/ {print $2}'); then
    echo "ERROR: pdfinfo failed for $pdf" | tee -a "$ERRFILE"
    return 1
  fi
  if [[ -z "$pages" ]]; then
    echo "ERROR: cannot read page count for $pdf" | tee -a "$ERRFILE"
    return 1
  fi
  
  # Build prefix from directory structure
  local pdf_count
  pdf_count=$(find "$dir" -maxdepth 1 -type f -iname "*.pdf" | wc -l)
  local prefix
  local curr_dirname=$(basename "$dir")
  local parent=$(basename "$(dirname "$dir")")  
  local grandparent_dir=$(dirname "$(dirname "$dir")")
  local grandparent=$(basename "$grandparent_dir")

  if [[ "$pdf_count" -gt 1 ]]; then
    prefix="$base"
    echo "WARNING: Multiple PDFs in folder, using PDF name as prefix: $prefix" | tee -a "$ERRFILE"
    
    # Check for potential filename conflicts with existing files
    local conflict_found=false
    local expected_extensions=()
    
    # Determine expected file extensions based on output format
    if [[ "$OUTFMT" == "tif" ]]; then
      expected_extensions=("tif")
    elif [[ "$OUTFMT" == "jpg" ]]; then
      expected_extensions=("jpg")
    else
      expected_extensions=("tif" "jpg" "pbm" "pgm" "ppm")
    fi
    
    # Check for conflicts with existing files
    for ext in "${expected_extensions[@]}"; do
      if ls "${dir}/${prefix}_"[0-9][0-9][0-9][0-9]."${ext}" >/dev/null 2>&1; then
        conflict_found=true
        echo "ERROR: Filename conflict detected in $pdf" | tee -a "$ERRFILE"
        echo "ERROR: Existing files found matching pattern ${prefix}_NNNN.${ext}" | tee -a "$ERRFILE"
        echo "ERROR: Manual intervention required - please rename or move existing files" | tee -a "$ERRFILE"
        break
      fi
    done
    
    if [[ "$conflict_found" == true ]]; then
      return 1
    fi
    
  else
    # Single PDF in folder - use directory structure naming
    if [[ -n "$grandparent" && "$grandparent" != "/" && "$grandparent" != "." ]]; then
      prefix="${grandparent}_${parent}_nr_${curr_dirname}"
      
      # Check for filename conflicts in single PDF scenario
      local conflict_found=false
      local expected_extensions=()
      
      if [[ "$OUTFMT" == "tif" ]]; then
        expected_extensions=("tif")
      elif [[ "$OUTFMT" == "jpg" ]]; then
        expected_extensions=("jpg")
      else
        expected_extensions=("tif" "jpg" "pbm" "pgm" "ppm")
      fi
      
      for ext in "${expected_extensions[@]}"; do
        if ls "${dir}/${prefix}_"[0-9][0-9][0-9][0-9]."${ext}" >/dev/null 2>&1; then
          conflict_found=true
          echo "WARNING: Potential filename conflict in $pdf" | tee -a "$ERRFILE"
          echo "WARNING: Existing files found matching pattern ${prefix}_NNNN.${ext}" | tee -a "$ERRFILE"
          echo "WARNING: Proceeding with extraction - manual verification recommended" | tee -a "$ERRFILE"
          break
        fi
      done
      
    else
      prefix="${base}"
    fi
  fi
 
  # sanitize prefix (replace spaces with underscore to be safe)
  prefix="${prefix// /_}"

  # --- Extract images ---
  local temp_prefix="${prefix}_temp_$$"  # Use temporary prefix to avoid conflicts
  
  if [[ "$OUTFMT" == "tif" ]]; then
    pdfimages -tiff "$pdf" "${dir}/${temp_prefix}" 2>>"$ERRFILE"
  elif [[ "$OUTFMT" == "jpg" ]]; then
    pdfimages -j "$pdf" "${dir}/${temp_prefix}" 2>>"$ERRFILE"
  else
    pdfimages -all "$pdf" "${dir}/${temp_prefix}" 2>>"$ERRFILE"
  fi
  local status=$?

  if [[ $status -ne 0 ]]; then
    echo "ERROR: pdfimages failed for $pdf" | tee -a "$ERRFILE"
    # Cleanup temporary files
    find "$dir" -name "${temp_prefix}-*" -type f -delete 2>/dev/null || true
    return 1
  fi

  # List and Count extracted images
  local extracted
  extracted=$(ls "${dir}/${temp_prefix}"-* 2>/dev/null || true)  
  local imgcount
  imgcount=$(echo "$extracted" | grep -c . || echo 0)

  if [[ "$imgcount" -eq 0 ]]; then
    echo "ERROR: no images extracted from $pdf" | tee -a "$ERRFILE"
    return 1
  fi

  # Compare page count and image count and if not cleanup wrong images
  if [[ "$imgcount" -ne "$pages" ]]; then
    find "$dir" -name "${temp_prefix}-*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
    echo "ERROR: mismatch in $pdf (expected $pages, got $imgcount)" | tee -a "$ERRFILE"
    return 1
  fi

  # Rename extracted files with final names (0001, 0002...) and Cleanup on failure
  local counter=1
  for file in $extracted; do
    local ext="${file##*.}"
    local newname=$(printf "%s_%04d.%s" "${prefix}" "$counter" "$ext")
    if ! mv "$file" "${dir}/${newname}"; then
      echo "ERROR: failed to rename $file to $newname" | tee -a "$ERRFILE"
      find "$dir" -name "${temp_prefix}-*" -type f -delete 2>/dev/null || true
      find "$dir" -name "${prefix}_*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
      return 1
    fi
    counter=$((counter+1))
  done

  echo "SUCCESS: $pdf extracted correctly ($imgcount pages)" | tee -a "$LOGFILE"
  
  # Move processed PDF, preserving folder structure
  local processed_dir="$WORKDIR/$TMPPDFDIR"
  if [[ -n "$grandparent" && "$grandparent" != "/" && "$grandparent" != "." ]]; then
    processed_dir="$processed_dir/$grandparent/$parent/$curr_dirname"
  else
    processed_dir="$processed_dir/$parent/$curr_dirname"
  fi

  # Create directory structure if needed
  if [[ ! -d "$processed_dir" ]]; then
    if ! mkdir -p "$processed_dir" 2>>"$ERRFILE"; then
      echo "ERROR: cannot create directory $processed_dir" | tee -a "$ERRFILE"
      find "$dir" -name "${prefix}_*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
      return 1
    fi
  fi
  
  local target="$processed_dir/$(basename "$pdf")"
  if [[ -f "$target" ]]; then
  local counter=1
  while [[ -f "${target%.pdf}_duplicate_${counter}.pdf" ]]; do
    ((counter++))
  done
  target="${target%.pdf}_duplicate_${counter}.pdf"
  echo "WARNING: Renamed duplicate to $(basename "$target")" | tee -a "$ERRFILE"
  fi
  
  if mv "$pdf" "$target"; then
    echo "Moved $pdf -> $target" | tee -a "$LOGFILE"
  else
    echo "ERROR: failed to move $pdf to $target" | tee -a "$ERRFILE"
    find "$dir" -name "${prefix}_*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
    return 1
  fi
}

# --- Main processing loop ---
total_pdfs=0
processed_pdfs=0
failed_pdfs=0

mapfile -t pdf_array < <(find "$WORKDIR" -type f -iname "*.pdf" -not -path "*/$TMPPDFDIR/*")

for pdf in "${pdf_array[@]}"; do
  echo "DEBUG: Found PDF: $pdf"
  ((total_pdfs++))
  echo "Progress: Processing PDF $total_pdfs - $(basename "$pdf")"
  
  if process_pdf "$pdf"; then
    ((processed_pdfs++))
  else
    ((failed_pdfs++))
  fi
done

# --- Final summary ---
echo | tee -a "$LOGFILE"
echo "=== PROCESSING SUMMARY ===" | tee -a "$LOGFILE"
echo "Total PDFs found: $total_pdfs" | tee -a "$LOGFILE"
echo "Successfully processed: $processed_pdfs" | tee -a "$LOGFILE"
echo "Failed: $failed_pdfs" | tee -a "$LOGFILE"

# Move log files to processed_pdfs with proper error handling
if [[ -f "$LOGFILE" ]]; then
  if cp "$LOGFILE" "$WORKDIR/$TMPPDFDIR/"; then
    rm -f "$LOGFILE"
    echo "Moved log file to $WORKDIR/$TMPPDFDIR/"
  else
    echo "WARNING: Failed to move log file to $TMPPDFDIR directory"
  fi
fi

if [[ -f "$ERRFILE" ]]; then
  if cp "$ERRFILE" "$WORKDIR/$TMPPDFDIR/"; then
    rm -f "$ERRFILE"
    echo "Moved error file to $WORKDIR/$TMPPDFDIR/"
  else
    echo "WARNING: Failed to move error file to $TMPPDFDIR directory"
  fi
fi

# Release lock
flock -u 200

echo "Done. Check log files in $WORKDIR/$TMPPDFDIR/ for details."