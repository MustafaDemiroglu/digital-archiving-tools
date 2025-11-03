#!/bin/bash

# Script Name: process_csv_files.sh
# Description: This script processes a CSV file to move and rename files based on predefined transformations.
# The script includes options like --verbose, --dry-run, --help, etc., for flexibility.
# Example usage: ./process_csv_files.sh --verbose input.csv

# Default values
verbose=false
dry_run=false
log_file="/tmp/archzeich/script.log"

# Function to print verbose log messages
verbose_log() {
  if $verbose; then
    echo "$1"
  fi
}

# Function to display help
show_help() {
  echo "Usage: ./process_csv_files.sh [OPTIONS] <csv_file>"
  echo ""
  echo "Options:"
  echo "  --verbose, -v    Enable verbose logging"
  echo "  --dry-run, -n    Perform a dry run (no actual changes will be made)"
  echo "  --help, -h       Show this help message"
  echo ""
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose)
      verbose=true
      shift
      ;;
    -n|--dry-run)
      dry_run=true
      shift
      ;;
    -h|--help)
      show_help
      exit 0
      ;;
    *)
      csv_file="$1"
      shift
      ;;
  esac
done

# Check if CSV file is provided
if [[ -z "$csv_file" ]]; then
  echo "Error: CSV file is required."
  show_help
  exit 1
fi

# Check if the CSV file exists
if [[ ! -f "$csv_file" ]]; then
  echo "Error: File '$csv_file' not found!"
  exit 1
fi

# Clean up old log files
> $log_file

# Read the CSV and process each line
while IFS=$'\t' read -r col1 col2 col3 col4 col5; do
  # Skip empty lines or lines that do not need processing
  if [[ -z "$col1" || -z "$col2" || -z "$col3" || -z "$col4" ]]; then
    continue
  fi

  # Transform the column data (sed-like operations)
  oldpathsig=$(echo "$col4" | sed -e 's# #_#g' \
                                   -e 's#.*#\L&#' \
                                   -e 's#_\([abcpr]_[1-9i]\)#/\1#' \
                                   -e 's#\([0-9]\)\/\([0-9]\)#\1--\2#g')
  pagepathsig=$(echo "$col5" | sed -e 's#\.jpe\?g$##' \
                                   -e 's#.*_nr_\(.*\)#\1#' \
                                   -e 's#_0*\([1-9]\)#_\1#g' \
                                   -e 's#\([0-9]\)_\([1-9]\)#\1--\2#' \
                                   -e 's#_\([rv]\)$#\1#')

  # Log the transformation
  verbose_log "Old path: $col4 -> $oldpathsig"
  verbose_log "New path: $col5 -> $pagepathsig"

  # If dry run, just log the action
  if $dry_run; then
    echo "Dry run: mv $col4 $pagepathsig" >> $log_file
  else
    # Check if source directory exists
    if [ ! -d "$col4" ]; then
      echo "Source directory '$col4' not found!" >> $log_file
      continue
    fi

    # Create directories if they don't exist
    if [ ! -d "$pagepathsig" ]; then
      mkdir -p "$pagepathsig"
      verbose_log "Created directory: $pagepathsig"
    fi

    # Move the files
    mv "$col4"/* "$pagepathsig"/
    verbose_log "Moved files from '$col4' to '$pagepathsig'"
  fi

done < "$csv_file"

# Final log message
echo "Processing complete. Check log file at $log_file."
