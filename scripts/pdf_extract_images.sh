#!/bin/bash
###############################################################################
# Script Name: pdf_extract_images.sh
# Version 4.1
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

# --- Acquire lock ---
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
  local pdf_lock_file="$LOCKDIR/$(echo "$pdf" | sed 's|/|_|g').lock"
  
  # Try to acquire lock for this specific PDF file
  exec 201>"$pdf_lock_file"
  if ! flock -n 201; then
    echo "SKIPPED: $pdf (already being processed by another worker)" | tee -a "$LOGFILE"
    return 0
  fi
  
  echo "Processing: $pdf" | tee -a "$LOGFILE"

  # Count pages
  local pages
  if ! pages=$(pdfinfo "$pdf" 2>/dev/null | awk '/Pages:/ {print $2}'); then
    echo "ERROR: pdfinfo failed for $pdf" | tee -a "$ERRFILE"
    flock -u 201
    return 1
  fi
  if [[ -z "$pages" ]]; then
    echo "ERROR: cannot read page count for $pdf" | tee -a "$ERRFILE"
    flock -u 201
    return 1
  fi
  
  # Build prefix from directory structure:
  # If a folder contains more than one PDF, always use pdfname_0001.ext naming
  # if there are at least two directory levels above the PDF's folder,
  # use grandparent_parent_nr_currentdir (e.g. hstam_karten_nr_cenk)
  # otherwise fallback to PDF base name
  local pdf_count
  pdf_count=$(find "$dir" -maxdepth 1 -type f -iname "*.pdf" | wc -l)
  local prefix
  curr_dirname=$(basename "$dir")
  parent=$(basename "$(dirname "$dir")")
  grandparent_dir=$(dirname "$(dirname "$dir")")
  grandparent=$(basename "$grandparent_dir")

  if [[ "$pdf_count" -gt 1 ]]; then
    prefix="$base"
    # Multiple PDFs in folder - check for filename conflicts
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
      # Check if any files exist that match our future naming pattern
      if ls "${dir}/${prefix}_"[0-9][0-9][0-9][0-9]."${ext}" >/dev/null 2>&1; then
        conflict_found=true
        echo "ERROR: Filename conflict detected in $pdf" | tee -a "$ERRFILE"
        echo "ERROR: Existing files found matching pattern ${prefix}_NNNN.${ext}" | tee -a "$ERRFILE"
        echo "ERROR: Manual intervention required - please rename or move existing files" | tee -a "$ERRFILE"
        break
      fi
    done
    
    if [[ "$conflict_found" == true ]]; then
      flock -u 201
      return 1
    fi
    
  else
    # Single PDF in folder - use directory structure naming
    if [[ -n "$grandparent" && "$grandparent" != "/" && "$grandparent" != "." ]]; then
      prefix="${grandparent}_${parent}_nr_${curr_dirname}"
      
      # Check for filename conflicts in single PDF scenario
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
      
      # Check for conflicts with existing files (excluding numbered sequences from PDFs)
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
  if [[ "$OUTFMT" == "tif" ]]; then
    pdfimages -tiff "$pdf" "${dir}/${prefix}" 2>>"$ERRFILE"
  elif [[ "$OUTFMT" == "jpg" ]]; then
    pdfimages -j "$pdf" "${dir}/${prefix}" 2>>"$ERRFILE"
  else
    pdfimages -all "$pdf" "${dir}/${prefix}" 2>>"$ERRFILE"
  fi
  local status=$?

  if [[ $status -ne 0 ]]; then
    echo "ERROR: no images extracted from $pdf" | tee -a "$ERRFILE"
    return 1
  fi

  # List extracted images
  local extracted
  extracted=$(ls "${dir}/${prefix}"-* 2>/dev/null || true)
  
  # Count extracted images
  local imgcount
  imgcount=$(echo "$extracted" | wc -w)

  if [[ "$imgcount" -eq 0 ]]; then
    echo "ERROR: no images extracted from $pdf" | tee -a "$ERRFILE"
    flock -u 201
    return 1
  fi

  # Compare page count and image count
  if [[ "$imgcount" -ne "$pages" ]]; then
    # cleanup wrong images (exclude PDF files to prevent accidental deletion)
    find "$dir" -name "${prefix}-*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
    echo "ERROR: mismatch in $pdf (expected $pages, got $imgcount)" | tee -a "$ERRFILE"
    flock -u 201
    return 1
  fi

  # Rename extracted files with 0001, 0002...
  local counter=1
  for file in $extracted; do
    local ext="${file##*.}"
    local newname=$(printf "%s_%04d.%s" "${prefix}" "$counter" "$ext")
    mv -f "$file" "${dir}/${newname}"
    counter=$((counter+1))
  done

  echo "SUCCESS: $pdf extracted correctly ($imgcount pages)" | tee -a "$LOGFILE"
  
  # Move processed PDF and images, preserving folder structure
  processed_dir="$WORKDIR/processed_pdfs/$grandparent/$parent/$curr_dirname"

  local target="$processed_dir/$(basename "$pdf")"
  if [[ -f "$target" ]]; then
    echo "WARNING: $target already exists, skipping move." | tee -a "$ERRFILE"
  else
    mkdir -p "$processed_dir" 2>>"$ERRFILE" || {
      echo "ERROR: cannot create directory $processed_dir" | tee -a "$ERRFILE"
      # cleanup images if PDF move fails
      find "$dir" -name "${prefix}_*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
      flock -u 201
      return 1
    }
    if mv "$pdf" "$processed_dir/"; then
      echo "Moved $pdf -> $processed_dir/" | tee -a "$LOGFILE"
    else
      echo "ERROR: failed to move $pdf to $processed_dir/" | tee -a "$ERRFILE"
      # cleanup images if PDF move fails
      find "$dir" -name "${prefix}_*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
      flock -u 201
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

# Find all PDFs and process in parallel with xargs -P , exception:processed_pdfs
find "$WORKDIR" -type f -iname "*.pdf" -not -path "*/processed_pdfs/*" | xargs -I{} -P "$CPUCOUNT" bash -c 'process_pdf "$@"' _ {}

# Move log and error files to processed_pdfs directory
mkdir -p "$WORKDIR/processed_pdfs"
if [[ -f "$LOGFILE" ]]; then
  mv "$LOGFILE" "$WORKDIR/processed_pdfs/"
  echo "Moved log file to $WORKDIR/processed_pdfs/$LOGFILE" | tee -a "$LOGFILE"
fi
if [[ -f "$ERRFILE" ]]; then
  mv "$ERRFILE" "$WORKDIR/processed_pdfs/"
  echo "Moved error file to $WORKDIR/processed_pdfs/$ERRFILE" | tee -a "$LOGFILE"
fi

# Cleanup lock directory
rm -rf "$LOCKDIR"

echo 
echo "Done. Check $LOGFILE and $ERRFILE for details." | tee -a "$LOGFILE"