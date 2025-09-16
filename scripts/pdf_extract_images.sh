#!/bin/bash
###############################################################################
# Script Name: pdf_extract_images.sh
# Version 2.8
# Author : Mustafa Demiropglu
#
# Description:
#   This script extracts each page from PDF files into separate images using 'pdfimages'.
#   It supports both TIFF (.tif) and JPEG (.jpg).
#   The script is designed to run on Linux, macOS, or WSL (Windows Subsystem).
#   Parallelized based on CPU count.
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
LOGFILE="pdf_extract_log.txt"
ERRFILE="pdf_extract_error.txt"
TMPPDFDIR="./processed_pdfs"
LOCKFILE="/tmp/pdf_extract.lock"

# --- Acquire lock ---
exec 200>"$LOCKFILE"
flock -n 200 || { echo "Another instance is running. Exiting."; exit 1; }

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

echo "Starting PDF extraction in: $WORKDIR"
echo "Output format: $OUTFMT"
echo "Log file: $LOGFILE"
echo "Error file: $ERRFILE"
echo

CPUCOUNT=$(nproc)
echo "Using up to $CPUCOUNT parallel jobs."

# --- Process PDF ---
process_pdf() {
  local pdf="$1"
  local base=$(basename "$pdf" .pdf)
  local dir=$(dirname "$pdf")

  echo "Processing: $pdf" | tee -a "$LOGFILE"

  # Count pages
  local pages
  pages=$(pdfinfo "$pdf" 2>/dev/null | awk '/Pages:/ {print $2}')
  if [[ -z "$pages" ]]; then
    echo "ERROR: cannot read page count for $pdf" | tee -a "$ERRFILE"
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

  if [[ "$pdf_count" -gt 1 ]]; then
    prefix="$base"
  else
    curr_dirname=$(basename "$dir")
    parent=$(basename "$(dirname "$dir")")
    grandparent_dir=$(dirname "$(dirname "$dir")")
    grandparent=$(basename "$grandparent_dir")
    if [[ -n "$grandparent" && "$grandparent" != "/" && "$grandparent" != "." ]]; then
      prefix="${grandparent}_${parent}_nr_${curr_dirname}"
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
  imgcount=$(ls "${dir}/${prefix}"-*."$OUTFMT" 2>/dev/null | wc -l)

  local imgcount
  imgcount=$(echo "$extracted" | wc -w)

  if [[ "$imgcount" -eq 0 ]]; then
    echo "ERROR: no images extracted from $pdf" | tee -a "$ERRFILE"
    return 1
  fi

  # Compare page count and image count
  if [[ "$imgcount" -ne "$pages" ]]; then
    # cleanup wrong images
    rm -f $extracted
    echo "ERROR: mismatch in $pdf (expected $pages, got $imgcount)" | tee -a "$ERRFILE"
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
  relative_dir="${dir#$WORKDIR/}"                     
  local processed_dir="$WORKDIR/processed_pdfs/$relative_dir"
  mkdir -p "$processed_dir"

  local target="$processed_dir/$(basename "$pdf")"
  if [[ -f "$target" ]]; then
    echo "WARNING: $target already exists, skipping move." | tee -a "$ERRFILE"
  else
    if mv "$pdf" "$processed_dir/"; then
      echo "Moved $pdf -> $processed_dir/" | tee -a "$LOGFILE"
    else
      echo "ERROR: failed to move $pdf" | tee -a "$ERRFILE"
      # --- cleanup images if PDF move fails ---
      rm -f "${dir}/${prefix}"_*."$OUTFMT"
      return 1
    fi
  fi
}

export -f process_pdf
export LOGFILE ERRFILE OUTFMT

# Find all PDFs and process in parallel with xargs -P
find "$WORKDIR" -type f -iname "*.pdf" | xargs -I{} -P "$CPUCOUNT" bash -c 'process_pdf "$@"' _ {}

echo
echo "Done. Check $LOGFILE and $ERRFILE for details."