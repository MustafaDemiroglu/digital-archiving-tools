#!/bin/bash
###############################################################################
# Script Name: pdf_extract_images.sh
# Version 5.2
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
VERBOSE="${VERBOSE:-0}"   # set VERBOSE=1 in env to enable shell debug prints

# --- Helper for logging ---
log() { echo "$(date +"%F %T") [INFO] $*" | tee -a "$LOGFILE"; }
warn() { echo "$(date +"%F %T") [WARN] $*" | tee -a "$ERRFILE" "$LOGFILE"; }
err() { echo "$(date +"%F %T") [ERROR] $*" | tee -a "$ERRFILE" "$LOGFILE"; }

# --- Acquire main lock ---
exec 200>"$LOCKFILE"
flock -n 200 || { echo "Another instance is running. Exiting." | tee -a "$ERRFILE"; exit 1; }

cleanup_and_exit() {
  local rc=${1:-0}
  # Release lock
  flock -u 200 || true
  # Move logs even on error if possible
  if [[ -d "$WORKDIR/$TMPPDFDIR" ]]; then
    mv -f "$LOGFILE" "$WORKDIR/$TMPPDFDIR/" 2>/dev/null || true
    mv -f "$ERRFILE" "$WORKDIR/$TMPPDFDIR/" 2>/dev/null || true
  fi
  exit "$rc"
}
trap 'cleanup_and_exit $?' EXIT INT TERM

# --- Ask for format if not provided ---
if [[ -z "$OUTFMT" ]]; then
  read -p "Which output format do you want (tif/jpg/all)? " OUTFMT
fi
OUTFMT=$(echo "$OUTFMT" | tr '[:upper:]' '[:lower:]')

if [[ "$OUTFMT" != "tif" && "$OUTFMT" != "jpg" && "$OUTFMT" != "all" ]]; then
  err "Error: output format must be 'tif' or 'jpg' or 'all'"
  exit 1
fi

# --- Prepare directories and logs ---
mkdir -p "$WORKDIR/$TMPPDFDIR"
: > "$LOGFILE"
: > "$ERRFILE"

log "Starting PDF extraction in: $WORKDIR"
log "Output format: $OUTFMT"
log "Log file: $LOGFILE"
log "Error file: $ERRFILE"
log "Running in sequential mode (one PDF at a time). It can take a while."

# Optional verbose shell debug
if [[ "$VERBOSE" -eq 1 ]]; then
  echo "DEBUG: running find on $WORKDIR" | tee -a "$LOGFILE"
  find "$WORKDIR" -type f -iname '*.pdf' -not -path '*/processed_pdfs/*' | tee -a "$LOGFILE"
fi

mapfile -t -d '' pdf_array < <(
  find "$WORKDIR" -type f -iname '*.pdf' -not -path '*/processed_pdfs/*' -print0
)

# --- Process PDF ---
process_pdf() {
  local pdf="$1"
  local base dir pages prefix temp_prefix extracted imgcount status parent curr_dirname grandparent grandparent_dir pdf_count

  base=$(basename "$pdf" .pdf)
  dir=$(dirname "$pdf")
  curr_dirname=$(basename "$dir")
  parent=$(basename "$(dirname "$dir")")
  grandparent_dir=$(dirname "$(dirname "$dir")")
  grandparent=$(basename "$grandparent_dir")

  log "Processing: $pdf"
  
  # Count pages
  if ! pages=$(pdfinfo "$pdf" 2>/dev/null | awk '/Pages:/ {print $2}'); then
    err "pdfinfo failed for $pdf"
    return 1
  fi
  if [[ -z "$pages" ]]; then
    err "cannot read page count for $pdf"
    return 1
  fi
  
  # Build prefix from directory structure
  pdf_count=$(find "$dir" -maxdepth 1 -type f -iname "*.pdf" | wc -l)

  if [[ "$pdf_count" -gt 1 ]]; then
    prefix="$base"
    warn "Multiple PDFs in folder, using PDF name as prefix: $prefix"
	# Check for potential filename conflicts with existing file
    # Determine expected file extensions based on output format
	expected_extensions=()
    if [[ "$OUTFMT" == "tif" ]]; then expected_extensions=("tif")
    elif [[ "$OUTFMT" == "jpg" ]]; then expected_extensions=("jpg")
    else expected_extensions=("tif" "jpg" "pbm" "pgm" "ppm"); fi
    
    # Check for conflicts with existing files
    for ext in "${expected_extensions[@]}"; do
      if ls "${dir}/${prefix}_"[0-9][0-9][0-9][0-9]."${ext}" >/dev/null 2>&1; then
        err "Filename conflict detected in $pdf (found ${prefix}_NNNN.${ext})"
        return 1
      fi
    done
  else
    # Single PDF in folder - use directory structure naming
    if [[ -n "$grandparent" && "$grandparent" != "/" && "$grandparent" != "." ]]; then
      prefix="${grandparent}_${parent}_nr_${curr_dirname}"      
      # Check for filename conflicts in single PDF scenario
      expected_extensions=()
      if [[ "$OUTFMT" == "tif" ]]; then expected_extensions=("tif")
      elif [[ "$OUTFMT" == "jpg" ]]; then expected_extensions=("jpg")
      else expected_extensions=("tif" "jpg" "pbm" "pgm" "ppm"); fi
      
      for ext in "${expected_extensions[@]}"; do
        if ls "${dir}/${prefix}_"[0-9][0-9][0-9][0-9]."${ext}" >/dev/null 2>&1; then
          warn "Potential filename conflict in $pdf (found ${prefix}_NNNN.${ext}) - proceeding"
          break
        fi
      done
    else
      prefix="${base}"
    fi
  fi
 
  # sanitize prefix (replace spaces with underscore to be safe)
  prefix="${prefix// /_}"
  temp_prefix="${prefix}_temp_$$"  # Use temporary prefix to avoid conflicts

  # --- Extract images ---
  if [[ "$OUTFMT" == "tif" ]]; then
    pdfimages -tiff "$pdf" "${dir}/${temp_prefix}" 2>>"$ERRFILE"
  elif [[ "$OUTFMT" == "jpg" ]]; then
    pdfimages -j "$pdf" "${dir}/${temp_prefix}" 2>>"$ERRFILE"
  else
    pdfimages -all "$pdf" "${dir}/${temp_prefix}" 2>>"$ERRFILE"
  fi
  local status=$?

  if [[ $status -ne 0 ]]; then
    err "pdfimages failed for $pdf (status $status)"
    find "$dir" -name "${temp_prefix}-*" -type f -delete 2>/dev/null || true
    return 1
  fi

  # List and Count extracted images
  mapfile -t extracted_arr < <(find "$dir" -maxdepth 1 -type f -name "${temp_prefix}-*" -print0 | xargs -0 -r -n1 echo || true)
  imgcount=${#extracted_arr[@]}

   if [[ "$imgcount" -eq 0 ]]; then
    err "no images extracted from $pdf"
    return 1
  fi

  # Compare page count and image count and if not cleanup wrong images
  if [[ "$imgcount" -ne "$pages" ]]; then
    find "$dir" -name "${temp_prefix}-*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
    err "mismatch in $pdf (expected $pages, got $imgcount)"
    return 1
  fi

  # Rename extracted files with final names (0001, 0002...) and Cleanup on failure
  local counter=1
  # sort files to ensure order
  IFS=$'\n' sorted=($(printf "%s\n" "${extracted_arr[@]}" | sort))
  unset IFS
  for file in "${sorted[@]}"; do
    ext="${file##*.}"
    newname=$(printf "%s_%04d.%s" "${prefix}" "$counter" "$ext")
    if ! mv -n -- "$file" "${dir}/${newname}"; then
      err "failed to rename $file to $newname"
      find "$dir" -name "${temp_prefix}-*" -type f -delete 2>/dev/null || true
      find "$dir" -name "${prefix}_*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
      return 1
    fi
    counter=$((counter+1))
  done

  log "SUCCESS: $pdf extracted correctly ($imgcount pages)"
  
  # Move processed PDF, preserving folder structure
  processed_dir="$WORKDIR/$TMPPDFDIR"
  if [[ -n "$grandparent" && "$grandparent" != "/" && "$grandparent" != "." ]]; then
    processed_dir="$processed_dir/$grandparent/$parent/$curr_dirname"
  else
    processed_dir="$processed_dir/$parent/$curr_dirname"
  fi

  # Create directory structure if needed
  if ! mkdir -p "$processed_dir" 2>>"$ERRFILE"; then
    err "cannot create directory $processed_dir"
    find "$dir" -name "${prefix}_*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
    return 1
  fi
  
  target="$processed_dir/$(basename "$pdf")"
  if [[ -f "$target" ]]; then
    local dupc=1
    while [[ -f "${target%.pdf}_duplicate_${dupc}.pdf" ]]; do ((dupc++)); done
    target="${target%.pdf}_duplicate_${dupc}.pdf"
    warn "Renamed duplicate to $(basename "$target")"
  fi
  
  if mv -n -- "$pdf" "$target"; then
    log "Moved $pdf -> $target"
  else
    err "failed to move $pdf to $target"
    find "$dir" -name "${prefix}_*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
    return 1
  fi

  return 0
}

# --- Main processing loop ---
total_pdfs=0
processed_pdfs=0
failed_pdfs=0

# Safety check
if [[ -z "$WORKDIR" || -z "$TMPPDFDIR" ]]; then
  echo "ERROR: WORKDIR or TMPPDFDIR is not set!" >&2
  exit 1
fi

while IFS= read -r -d '' pdf; do
  ((total_pdfs++))
  echo "DEBUG: Found PDF: $pdf"
  echo "Progress: Processing PDF $total_pdfs - $(basename "$pdf")"
  if process_pdf "$pdf"; then
    ((processed_pdfs++))
  else
    ((failed_pdfs++))
  fi
done < <(find "$WORKDIR" -type f -iname "*.pdf" ! -path "*/$TMPPDFDIR/*" -print0)

# --- Final summary ---
echo | tee -a "$LOGFILE"
log "=== PROCESSING SUMMARY ==="
log "Total PDFs found: $total_pdfs"
log "Successfully processed: $processed_pdfs"
log "Failed: $failed_pdfs"

# Move final logs to processed_pdfs if possible
if [[ -d "$WORKDIR/$TMPPDFDIR" ]]; then
  mv -f "$LOGFILE" "$WORKDIR/$TMPPDFDIR/" 2>/dev/null || warn "Failed to move log file to $WORKDIR/$TMPPDFDIR/"
  mv -f "$ERRFILE" "$WORKDIR/$TMPPDFDIR/" 2>/dev/null || warn "Failed to move error file to $WORKDIR/$TMPPDFDIR/"
fi

# Release lock and normal exit
flock -u 200
trap - EXIT
exit 0