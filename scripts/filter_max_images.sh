#!/bin/bash

# This script will:
# 1. Delete the 'thumb' folder in each signature folder.
# 2. Move all images from the 'max' folder to the signature folder.
# 3. Remove the now-empty 'max' folder.
#
# It will do this for each folder under any directory that contains 'max' and 'thumb' folders.

# Define the root directory where your folders are located
BASE_DIR="/media/cepheus/pstr_nutzungsdigis_secure_20260302"

# Loop through each directory (e.g., 900, 901, 902...)
for dir in ${BASE_DIR}/*; do
    if [[ -d "$dir" ]]; then  # Ensure it's a directory
        echo "Processing directory: $dir"

        # Loop through each subdirectory (e.g., 6584, 6585) inside the current directory
        for signature in "$dir"/*; do
            if [[ -d "$signature" ]]; then  # Ensure it's a directory
                echo "  Processing signature folder: $signature"

                # Step 1: Check if the 'max' and 'thumb' directories exist
                if [[ -d "${signature}/max" && -d "${signature}/thumb" ]]; then
                    # Step 2: Remove 'thumb' folder if it exists
                    echo "    Deleting 'thumb' folder..."
                    rm -rf "${signature}/thumb"

                    # Step 3: Move all images from 'max' folder to the signature folder
					if [[ "$(ls -A ${signature}/max)" ]]; then
                        echo "    Moving images from 'max' folder to signature folder..."
                        mv "${signature}/max"/* "${signature}/"
                    else

                    # Step 4: Remove the 'max' folder
                    echo "    Deleting 'max' folder..."
                    rmdir "${signature}/max"
                else
                    echo "    Skipping folder ${signature} as it does not contain both 'max' and 'thumb'."
                fi
            fi
        done
    fi
done

echo "Processing complete."