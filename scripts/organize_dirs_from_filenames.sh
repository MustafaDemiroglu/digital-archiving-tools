#!/bin/bash
###############################################################################
# Script Name: organize_dirs_from_filenames.sh (v 1.2)
# Author: Mustafa Demiroglu 
# Description:
#   This script organizes .tif files into specific folder structures based on
#   their filenames. The folder structure is determined by extracting parts of
#   the filenames: 'haus', 'bestand', and 'stück', and creating the necessary
#   directories if they do not already exist. Files are then moved into the
#   appropriate directories.
#
#   Example file name: hstam_karten_nr_c_261_b--2_0002.tif
#   Will be organized into: hstam/karten/c_261_b--2/hstam_karten_nr_c_261_b--2_0002.tif
#
# Usage:
#   ./organize_files.sh
#   Make sure the script is in the same directory as the files to be organized.
#
# Requirements:
#   - Bash shell
#   - Linux or WSL environment
#   - Files should be in the same directory as the script
###############################################################################

# Loop through all the .tif files in the current directory
for file in *.tif; do
    # Extract parts of the filename using regular expressions
    # We assume the format is: <haus>_<bestand>_nr_<stück>_<number>.tif
    if [[ "$file" =~ ^([a-zA-Z0-9]+)_([a-zA-Z0-9]+)_nr_([a-zA-Z0-9_-]+)_([0-9]+)\.tif$ ]]; then
        haus="${BASH_REMATCH[1]}"     # Haus (e.g., hstam)
        bestand="${BASH_REMATCH[2]}"  # Bestand (e.g., karten)
        stueck="${BASH_REMATCH[3]}"   # Stück (e.g., c_261_b--2)
        number="${BASH_REMATCH[4]}"   # Number (e.g., 0002)
        
        # Define the directory structure: haus/bestand/stueck
        dir="$haus/$bestand/$stueck"
        
        # Check if the directory structure exists, if not, create it
        if [ ! -d "$dir" ]; then
            echo "Creating directory: $dir"
            mkdir -p "$dir"
        fi
        
        # Move the file to the correct directory
        echo "Moving file '$file' to '$dir/$file'"
        mv "$file" "$dir/$file"
    else
        echo "Skipping file '$file' - does not match expected format."
    fi
done

echo "All files have been organized."
