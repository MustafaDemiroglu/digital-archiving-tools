#!/bin/bash
###############################################################################
# Script Name: pdf_extract_images.sh
# Version 4.2
# Author : Mustafa Demiroglu
#
# Description:
#   This script extracts each page from PDF files into separate images using 'pdfimages'.
#   It supports both TIFF (.tif) and JPEG (.jpg).
#   The script is designed to run on Linux, macOS, or WSL (Windows Subsystem).
#   Parallelized based on CPU count with per-file locking to prevent race conditions.
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
#
###############################################################################

set -euo pipefail

# --- Setup ---
WORKDIR="${1:-$(pwd)}"    # Path to work on, default = current dir
OUTFMT="${2:-}"               # Desired image format (tif or jpg)
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOGFILE="log_pdf_extract_${TIMESTAMP}.txt"
ERRFILE="error_pdf_extract_${TIMESTAMP}.txt"
TMPPDFDIR="./processed_pdfs"
LOCKFILE="/tmp/pdf_extract.lock"
LOCKDIR="/tmp/pdf_extract_locks"

# Create lock directory for individual file locks
mkdir -p "$LOCKDIR"

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

# --- Clear log files from previous runs ---
: > "$LOGFILE"
: > "$ERRFILE"

echo "Starting PDF extraction in: $WORKDIR" | tee -a "$LOGFILE"
echo "Output format: $OUTFMT" | tee -a "$LOGFILE"
echo "Log file: $LOGFILE" | tee -a "$LOGFILE"
echo "Error file: $ERRFILE" | tee -a "$LOGFILE"
echo "It can take a while to process all PDFs" | tee -a "$LOGFILE"

CPUCOUNT=$(nproc)
echo "Using up to $CPUCOUNT parallel jobs." | tee -a "$LOGFILE"

# --- Process PDF ---
process_pdf() {
  local pdf="$1"
  local base=$(basename "$pdf" .pdf)
  local dir=$(dirname "$pdf")

  # Create a unique lock file for this PDF to prevent multiple processes working on same file
  local pdf_hash=$(echo "$pdf" | md5sum | cut -d' ' -f1)
  local pdf_lock_file="$LOCKDIR/pdf_${pdf_hash}.lock"
  
  # Try to acquire exclusive lock for this specific PDF file
  exec 201>"$pdf_lock_file"
  if ! flock -n 201; then
    echo "SKIPPED: $pdf (already being processed by another worker)" >> "$LOGFILE"
    return 0
  fi
  
  # Double check if PDF still exists (might have been processed by another worker)
  if [[ ! -f "$pdf" ]]; then
    echo "SKIPPED: $pdf (file no longer exists, likely processed by another worker)" >> "$LOGFILE"
    flock -u 201
    rm -f "$pdf_lock_file"
    return 0
  fi
  
  echo "Processing: $pdf" >> "$LOGFILE"

  # Count pages
  local pages
  if ! pages=$(pdfinfo "$pdf" 2>/dev/null | awk '/Pages:/ {print $2}'); then
    echo "ERROR: pdfinfo failed for $pdf" >> "$ERRFILE"
    flock -u 201
    rm -f "$pdf_lock_file"
    return 1
  fi
  if [[ -z "$pages" ]]; then
    echo "ERROR: cannot read page count for $pdf" >> "$ERRFILE"
    flock -u 201
    rm -f "$pdf_lock_file"
    return 1
  fi
  
  # Build prefix from directory structure
  local pdf_count
  pdf_count=$(find "$dir" -maxdepth 1 -type f -iname "*.pdf" | wc -l)
  local prefix
  curr_dirname=$(basename "$dir")
  parent=$(basename "$(dirname "$dir")")
  grandparent_dir=$(dirname "$(dirname "$dir")")
  grandparent=$(basename "$grandparent_dir")

  if [[ "$pdf_count" -gt 1 ]]; then
    prefix="$base"
    echo "WARNING: Multiple PDFs in folder, using PDF name as prefix: $prefix" >> "$ERRFILE"
    
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
        echo "ERROR: Filename conflict detected in $pdf" >> "$ERRFILE"
        echo "ERROR: Existing files found matching pattern ${prefix}_NNNN.${ext}" >> "$ERRFILE"
        echo "ERROR: Manual intervention required - please rename or move existing files" >> "$ERRFILE"
        break
      fi
    done
    
    if [[ "$conflict_found" == true ]]; then
      flock -u 201
      rm -f "$pdf_lock_file"
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
          echo "WARNING: Potential filename conflict in $pdf" >> "$ERRFILE"
          echo "WARNING: Existing files found matching pattern ${prefix}_NNNN.${ext}" >> "$ERRFILE"
          echo "WARNING: Proceeding with extraction - manual verification recommended" >> "$ERRFILE"
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
    echo "ERROR: pdfimages failed for $pdf" >> "$ERRFILE"
    # Cleanup temporary files
    find "$dir" -name "${temp_prefix}-*" -type f -delete 2>/dev/null || true
    flock -u 201
    rm -f "$pdf_lock_file"
    return 1
  fi

  # List extracted images
  local extracted
  extracted=$(ls "${dir}/${temp_prefix}"-* 2>/dev/null || true)
  
  # Count extracted images
  local imgcount
  imgcount=$(echo "$extracted" | grep -c . || echo 0)

  if [[ "$imgcount" -eq 0 ]]; then
    echo "ERROR: no images extracted from $pdf" >> "$ERRFILE"
    flock -u 201
    rm -f "$pdf_lock_file"
    return 1
  fi

  # Compare page count and image count
  if [[ "$imgcount" -ne "$pages" ]]; then
    # cleanup wrong images
    find "$dir" -name "${temp_prefix}-*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
    echo "ERROR: mismatch in $pdf (expected $pages, got $imgcount)" >> "$ERRFILE"
    flock -u 201
    rm -f "$pdf_lock_file"
    return 1
  fi

  # Rename extracted files with final names (0001, 0002...)
  local counter=1
  for file in $extracted; do
    local ext="${file##*.}"
    local newname=$(printf "%s_%04d.%s" "${prefix}" "$counter" "$ext")
    if ! mv "$file" "${dir}/${newname}"; then
      echo "ERROR: failed to rename $file to $newname" >> "$ERRFILE"
      # Cleanup on failure
      find "$dir" -name "${temp_prefix}-*" -type f -delete 2>/dev/null || true
      find "$dir" -name "${prefix}_*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
      flock -u 201
      rm -f "$pdf_lock_file"
      return 1
    fi
    counter=$((counter+1))
  done

  echo "SUCCESS: $pdf extracted correctly ($imgcount pages)" >> "$LOGFILE"
  
  # Move processed PDF, preserving folder structure
  local processed_dir="$WORKDIR/processed_pdfs"
  if [[ -n "$grandparent" && "$grandparent" != "/" && "$grandparent" != "." ]]; then
    processed_dir="$processed_dir/$grandparent/$parent/$curr_dirname"
  else
    processed_dir="$processed_dir/$parent/$curr_dirname"
  fi

  local target="$processed_dir/$(basename "$pdf")"
  if [[ -f "$target" ]]; then
    echo "WARNING: $target already exists, skipping move." >> "$ERRFILE"
  else
    if ! mkdir -p "$processed_dir" 2>>"$ERRFILE"; then
      echo "ERROR: cannot create directory $processed_dir" >> "$ERRFILE"
      # cleanup images if PDF move fails
      find "$dir" -name "${prefix}_*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
      flock -u 201
      rm -f "$pdf_lock_file"
      return 1
    fi
    
    if mv "$pdf" "$processed_dir/"; then
      echo "Moved $pdf -> $processed_dir/" >> "$LOGFILE"
    else
      echo "ERROR: failed to move $pdf to $processed_dir/" >> "$ERRFILE"
      # cleanup images if PDF move fails
      find "$dir" -name "${prefix}_*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
      flock -u 201
      rm -f "$pdf_lock_file"
      return 1
    fi
  fi
  
  # Release the lock for this PDF
  flock -u 201
  
  # Remove the lock file
  rm -f "$pdf_lock_file"
}

export -f process_pdf
export LOGFILE ERRFILE OUTFMT WORKDIR LOCKDIR

# Find all PDFs and process in parallel with xargs -P, excluding processed_pdfs
find "$WORKDIR" -type f -iname "*.pdf" -not -path "*/processed_pdfs/*" | \
  xargs -I{} -P "$CPUCOUNT" bash -c 'process_pdf "$@"' _ {}

# Wait for all background processes to complete
wait

# Create processed_pdfs directory if it doesn't exist
mkdir -p "$WORKDIR/processed_pdfs"

# Move log and error files to processed_pdfs directory
if [[ -f "$LOGFILE" ]]; then
  if cp "$LOGFILE" "$WORKDIR/processed_pdfs/"; then
    rm -f "$LOGFILE"
    echo "Moved log file to $WORKDIR/processed_pdfs/$LOGFILE"
  else
    echo "ERROR: Failed to move log file to processed_pdfs directory"
  fi
fi

if [[ -f "$ERRFILE" ]]; then
  if cp "$ERRFILE" "$WORKDIR/processed_pdfs/"; then
    rm -f "$ERRFILE" 
    echo "Moved error file to $WORKDIR/processed_pdfs/$ERRFILE"
  else
    echo "ERROR: Failed to move error file to processed_pdfs directory"
  fi
fi

# Cleanup lock directory
rm -rf "$LOCKDIR"

# Release main lock
flock -u 200

echo 
echo "Done. Check log and error files in $WORKDIR/processed_pdfs/ for details."