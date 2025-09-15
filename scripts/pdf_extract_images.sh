#!/bin/bash
###############################################################################
# Script Name: pdf_extract_images.sh
# Version 1.1
# Author : Mustafa Demiropglu
#
# Description:
#   This script extracts each page from PDF files into separate images.
#   It supports both TIFF (.tif) and JPEG (.jpg).
#   The script is designed to run on Linux, macOS, or WSL (Windows Subsystem).
#
# How it works:
#   1. If you do not provide a path, it works in the current folder and subfolders.
#   2. You can choose the output format (tif or jpg). If not provided, the script asks you.
#   3. Each PDF is processed page by page at best possible quality.
#   4. Output images are named like: pdfname_0001.tif / pdfname_0001.jpg
#   5. After extraction, it checks if the number of created images equals
#      the number of PDF pages.
#   6. If correct, the original PDF is moved to a temporary folder "processed_pdfs".
#   7. A log file is created with results and errors.
#
# Requirements:
#   - ImageMagick (for 'magick' or 'convert')
#   - pdfinfo (from poppler-utils package, to count PDF pages)
#
# Example usage:
#   ./pdf_extract_images.sh                # process PDFs in current dir
#   ./pdf_extract_images.sh /path/to/data  # process PDFs in given folder
#   ./pdf_extract_images.sh /data jpg      # extract as jpg instead of tif
#
###############################################################################

# --- Setup ---
WORKDIR="${1:-$(pwd)}"    # Path to work on, default = current dir
OUTFMT="$2"               # Desired image format (tif or jpg)
LOGFILE="pdf_extract_log.txt"
ERRFILE="pdf_extract_error.txt"
TMPPDFDIR="./processed_pdfs"

# --- Ask for format if not provided ---
if [[ -z "$OUTFMT" ]]; then
  read -p "Which output format do you want (tif/jpg)? " OUTFMT
fi
OUTFMT=$(echo "$OUTFMT" | tr '[:upper:]' '[:lower:]')

if [[ "$OUTFMT" != "tif" && "$OUTFMT" != "jpg" ]]; then
  echo "Error: output format must be 'tif' or 'jpg'" | tee -a "$ERRFILE"
  exit 1
fi

# --- Prepare folders ---
mkdir -p "$TMPPDFDIR"

# --- Clear log files from previous runs ---
: > "$LOGFILE"
: > "$ERRFILE"

echo "Starting PDF extraction in: $WORKDIR"
echo "Output format: $OUTFMT"
echo "Log file: $LOGFILE"
echo "Error file: $ERRFILE"
echo

# --- Process each PDF ---
find "$WORKDIR" -type f -iname "*.pdf" | while read -r pdf; do
  echo "Processing: $pdf" | tee -a "$LOGFILE"

  base=$(basename "$pdf" .pdf)
  dir=$(dirname "$pdf")

  # Count pages using pdfinfo
  pages=$(pdfinfo "$pdf" 2>/dev/null | awk '/Pages:/ {print $2}')
  if [[ -z "$pages" ]]; then
    echo "ERROR: cannot read page count for $pdf" | tee -a "$ERRFILE"
    continue
  fi

  # Extract images
  magick -density 300 "$pdf" "${dir}/${base}_%04d.${OUTFMT}" 2>>"$ERRFILE"
  if [[ $? -ne 0 ]]; then
    echo "ERROR: failed to extract $pdf" | tee -a "$ERRFILE"
    continue
  fi

  # Count extracted images
  imgcount=$(ls "${dir}/${base}"_*."$OUTFMT" 2>/dev/null | wc -l)

  if [[ "$imgcount" -eq "$pages" ]]; then
    echo "SUCCESS: $pdf extracted correctly ($imgcount pages)" | tee -a "$LOGFILE"
    mv "$pdf" "$TMPPDFDIR/"
  else
    echo "ERROR: mismatch in $pdf (expected $pages, got $imgcount)" | tee -a "$ERRFILE"
  fi
done

echo
echo "Done. Check $LOGFILE and $ERRFILE for details."