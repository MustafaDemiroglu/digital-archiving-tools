# archive_clean_and_rename.py  
A safe, cross-platform tool for cleaning and renaming archival directories and files according to the **Hessisches Landesarchiv (HLA) Benennungsrichtlinie**.

This script was developed to support digital archival workflows, ensuring:
- Correct folder naming conventions (Umlaut mapping, allowed characters, removal of invalid characters, etc.)
- Safe and deterministic renaming of image/PDF files
- Strict depth validation (to avoid running in the wrong directory)
- Full logging of all actions
- A **dry-run mode** (`-n` / `--dry-run`) for safe previewing of changes

---

## Features

### ✔ Folder Name Normalization (HLA Compliant)
Follows HLA rules:
- Lowercase only  
- `ä → ae`, `ö → oe`, `ü → ue`, `ß → ss`  
- `/ → --`  
- `+ → ..`  
- spaces → `_`  
- commas removed entirely  
- invalid characters are fully removed  
- only `[a-z0-9._-]` are allowed in final names  

### ✔ Safe File Renaming  
Files inside leaf directories are renamed using:

grandfather_father_nr_root_0001.ext
grandfather_father_nr_root_0002.ext
...



Missing parent folders are replaced with `x`.

Supports extensions:

.tif, .tiff, .jpg, .jpeg, .png, .pdf
(upper or lower case)


### ✔ Depth Validation  
Before processing, the script checks that **no file is located deeper than 4 directory levels** relative to the chosen root directory.

If violated → The script aborts safely.

### ✔ Dry-Run Mode (`-n` / `--dry-run`)  
Simulates ALL changes:
- No rename
- No move
- No deletion
- No temp directory creation  
- But logs all potential actions  
Perfect for verifying before running in production.

### ✔ Logging  
A log file is created under the chosen root directory:
archive_rename_log_YYYYMMDD_HHMMSS.log


Includes actions, warnings, and errors.

### ✔ Safety  
- **Never renames the root directory**
- Avoids overwriting files
- Uses temporary directories for safe operations
- Folder rename rollback during errors (non-dry-run)

---

## Installation

This script requires **Python 3.6+**.

### Clone the repository:
''' bash
git clone https://github.com/Mustafa.Demiroglu/archive-clean-rename.git
cd archive-clean-rename
''' text
## Usage
### Dry-run (recommended first):
python3 archive_clean_and_rename.py -n /path/to/root

### Actual run:
python3 archive_clean_and_rename.py /path/to/root

### Without argument (interactive):
python3 archive_clean_and_rename.py

Script will ask:
No path given. Run in current directory '/your/path'? (y/n):

### Example Directory Depth

Valid structure:

festplatte/
  secure/
    haus/
      bestand/
        signatur/
          file_001.tif

Relative depth = 4 → allowed.

If deeper than 4 levels → script aborts automatically.

### Temporary Directory

During real runs (not dry-run), a temp directory is created automatically:

tmp_archive_renamer_<pid>

It is removed after successful processing.


## License

This project is licensed under the MIT License.
See the LICENSE file for details.

## Contributions

Pull requests are welcome.
Issues / feature requests can be submitted via GitHub Issues.

## Author

Originally developed by Mustafa Demiroğlu,
Data Steward & Digital Archival Workflow Spezialist
