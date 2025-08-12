#!/usr/bin/env python3

"""
cleanup_workflow.py

Simple script to organize and clean files in the 'archive' folder.
Example: remove files smaller than 1 KB and rename files to lowercase.
"""

import os

ARCHIVE_DIR = './archive'

def cleanup_archive():
    if not os.path.exists(ARCHIVE_DIR):
        print(f"Archive folder not found: {ARCHIVE_DIR}")
        return

    for filename in os.listdir(ARCHIVE_DIR):
        filepath = os.path.join(ARCHIVE_DIR, filename)

        if os.path.isfile(filepath):
            size = os.path.getsize(filepath)

            # Remove very small files (less than 1KB)
            if size < 1024:
                print(f"Removing small file: {filename} ({size} bytes)")
                os.remove(filepath)
                continue

            # Rename files to lowercase
            lower_name = filename.lower()
            if filename != lower_name:
                new_path = os.path.join(ARCHIVE_DIR, lower_name)
                print(f"Renaming {filename} to {lower_name}")
                os.rename(filepath, new_path)

if __name__ == "__main__":
    cleanup_archive()