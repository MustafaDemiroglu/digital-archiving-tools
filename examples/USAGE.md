# Usage Guide for Digital Archiving Tools Examples

This document explains how to use the example workflows and scripts provided.

## Archiving Files

- Choose the folder where your important files are stored.
- Use the archiving script to copy these files to a dedicated archive folder.
- Make sure the archive folder has enough storage space and proper permissions.

## Metadata Extraction

- Configure the metadata extraction workflow to run automatically on new file uploads.
- Metadata helps you understand details like file size, modification date, and file type.
- Regular metadata extraction improves your archive’s searchability and management.

## Cleanup and Organization

- Run cleanup scripts regularly to remove unnecessary files (e.g., very small or temporary files).
- Use naming conventions consistently (such as lowercase filenames) to avoid duplicates or confusion.
- Keep your archive organized by sorting files into subfolders based on date, type, or project.

---

Following these steps will help maintain a clean and reliable digital archive.

# Usage Guide for Provided Scripts

This folder contains scripts useful for managing files and directories in digital archiving projects.  
Here is a brief guide on how to use each script.

---

### 1. `generate_multifileslist.sh`

- Reads a list of directories from a file and generates a list of all files inside them.
- Useful to collect all file paths from multiple folders under a common base directory.
- Helps automate gathering file lists for batch processing or archiving.

---

### 2. `path_cleaner_and_formatter.sh`

- Lists CSV files in the current folder and lets you pick one to process.
- Cleans up paths inside the CSV by removing certain prefixes and filenames.
- Removes duplicate directory entries to simplify the data.
- Useful for cleaning and normalizing file paths before archiving.

---

### 3. `rename_part_in_names.sh`

- Renames parts of filenames and folder names by replacing a specified string with a new string.
- Works recursively in the current folder and below.
- Useful for correcting naming errors or standardizing names in bulk.

---

**General Advice:**

- Always back up your data before running these scripts.
- Review generated output files or logs carefully.
- Test scripts on sample data to understand their effect.
- Use these tools to automate repetitive file management tasks safely.

---

