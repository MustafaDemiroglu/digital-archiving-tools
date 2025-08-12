# Digital Archiving Tools - Usage Guide

This guide provides general instructions on using the digital archiving tools effectively.

## Preparing Your Archive

- Before archiving, ensure your source files are complete and verified.
- Back up important data before running any automated scripts.
- Define a clear folder structure for your archive (e.g., by year, project, or document type).

## Running the Archiving Process

- Use provided scripts to automate copying and organizing files.
- Verify files are copied correctly and check for any errors in logs.
- Automate workflows where possible to reduce manual work.

## Maintaining Your Archive

- Extract and update metadata regularly to track file information.
- Clean up unnecessary files to save space and improve performance.
- Review your archive periodically to fix inconsistencies and reorganize if needed.

---

By following these guidelines, you will create a durable and easy-to-manage digital archive.


# Digital Archiving Scripts - Usage Guide

This document explains how to safely and effectively use the provided scripts in your digital archiving work.

## Preparation

- Ensure the input files (like `/tmp/multifiles.list` for the listing script) are prepared correctly.
- Check that you have permissions to read source directories and write output files.
- Always work on copies of important data first.

## Running the Scripts

### generate_multifileslist.sh

- Use this script when you want to create a complete list of all files from multiple directories.
- Prepare a text file with directory paths, one per line.
- The script outputs a consolidated list of files which can be used for further processing.

### path_cleaner_and_formatter.sh

- Run this script inside the folder where your CSV files are stored.
- Follow the prompts to select the CSV file you want to clean.
- The script will remove unwanted parts from paths and remove duplicates to make data consistent.

### rename_part_in_names.sh

- Provide the old string and the new string as parameters.
- Confirm before renaming begins.
- Check the success and error logs after completion.
- This is useful for bulk renaming tasks to fix or standardize naming.

## Tips for Success

- Test scripts on a small dataset first.
- Make regular backups to avoid data loss.
- Read all prompts carefully before confirming operations.
- Use logs to verify results and troubleshoot if needed.

---

By following these instructions, you can streamline your digital archiving tasks safely and effectively.
