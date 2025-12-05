#!/usr/bin/env python3
"""
archive_clean_and_rename.py
version: 1. 0
Author: Mustafa Demiroglu
 
Simple, safe, cross-platform script to:
  - fix folder names according to HLA 'Benennungsrichtlinie'
  - then rename image/pdf files in deepest folders using:
      grandfather_father_nr_root_0001.ext
  - log all actions and errors

Usage:
  python3 archive_clean_and_rename.py /path/to/root
  python3 archive_clean_and_rename.py       # will ask interactively to use current dir

Notes / safety:
  - Script requires Python 3.6+
  - Allowed file extensions: .tif, .tiff, .jpg, .jpeg, .png, .pdf (case-insensitive)
  - If any file under the target root has relative directory depth > 4, the script aborts.
  - Temporary folder '._tmp_archive_renamer_<pid>' is created inside the root and removed at end.
  - Commas (',') are removed from names (per your specification).
  - All other disallowed characters are removed.
  - If a fatal error happens during folder renaming, the script tries to rollback changes.
"""

import argparse
import sys
import os
import shutil
import re
from pathlib import Path
from datetime import datetime
import tempfile
import unicodedata

# -----------------------
# Configuration
# -----------------------
ALLOWED_EXTS = {'.tif', '.tiff', '.jpg', '.jpeg', '.png', '.pdf'}
MAX_RELATIVE_DEPTH = 4  # if any file is deeper than this (relative to root) -> abort
TMP_DIR_PREFIX = "._tmp_archive_renamer_"
LOG_PREFIX = "archive_rename_log_"

# Regex for allowed folder/file characters AFTER transformation:
# allowed: a-z, 0-9, dot, dash, underscore
_ALLOWED_NAME_RE = re.compile(r'[^a-z0-9._-]')

# -----------------------
# Utilities
# -----------------------
def nowstr(fmt="%Y%m%d_%H%M%S"):
    return datetime.now().strftime(fmt)

def write_log(log_path: Path, line: str):
    with log_path.open("a", encoding="utf-8") as f:
        f.write(f"{datetime.now().isoformat()}  {line}\n")

# natural sort key: split strings into list of int and text parts
def natural_key(s: str):
    parts = re.split(r'(\d+)', s)
    key = []
    for p in parts:
        if p.isdigit():
            key.append(int(p))
        else:
            key.append(p.lower())
    return key

# sanitize according to HLA rules (for both folders and file-portion names)
def sanitize_name(name: str) -> str:
    # 1. Normalize unicode (NFKD) then replace common German umlauts
    name = unicodedata.normalize('NFKD', name)
    # lowercase
    name = name.lower()

    # Replace German umlauts/eszett as specified
    name = name.replace('ä', 'ae').replace('ö', 'oe').replace('ü', 'ue').replace('ß', 'ss')
    # Uppercase already lowered above

    # Replace slash with -- (two minus signs)
    name = name.replace('/', '--')

    # Replace plus with .. (two dots)
    name = name.replace('+', '..')

    # Replace spaces with _
    name = re.sub(r'\s+', '_', name)

    # Remove commas completely
    name = name.replace(',', '')

    # Remove any remaining non-allowed characters
    name = _ALLOWED_NAME_RE.sub('', name)

    # Collapse multiple underscores or dots or dashes
    name = re.sub(r'[_]{2,}', '_', name)
    name = re.sub(r'[.]{2,}', '..', name)  # keep double-dot as allowed mapping for plus
    name = re.sub(r'[-]{2,}', '--', name)

    # Trim leading/trailing separators
    name = name.strip('._-')

    # if empty, put 'x'
    if not name:
        return 'x'
    return name

# safe rename that avoids simple collisions by appending suffix if necessary
def unique_path(target: Path) -> Path:
    if not target.exists():
        return target
    base = target.stem
    ext = target.suffix
    parent = target.parent
    i = 1
    while True:
        candidate = parent / f"{base}_dup{i}{ext}"
        if not candidate.exists():
            return candidate
        i += 1

# -----------------------
# Main operations
# -----------------------
def check_max_relative_depth(root: Path, log_path: Path) -> bool:
    """
    Walk root and ensure no file lives deeper than MAX_RELATIVE_DEPTH directories
    relative to root. (If any file deeper, write log and return False)
    """
    max_found = 0
    for p in root.rglob('*'):
        if p.is_file():
            try:
                rel = p.parent.relative_to(root)
                depth = len(rel.parts)  # number of directories between root and the file's parent
            except Exception:
                depth = 0
            if depth > max_found:
                max_found = depth
    write_log(log_path, f"Max relative folder depth found: {max_found}")
    if max_found > MAX_RELATIVE_DEPTH:
        write_log(log_path, f"ABORT: found relative depth {max_found} > allowed {MAX_RELATIVE_DEPTH}")
        return False
    return True

def gather_dirs_by_depth(root: Path):
    """
    Return list of directories sorted by depth descending (deepest first).
    """
    dirs = [p for p in root.rglob('*') if p.is_dir()]
    dirs.append(root)  # include root itself
    dirs_sorted = sorted(dirs, key=lambda p: len(p.relative_to(root).parts), reverse=True)
    return dirs_sorted

def rename_directories_safe(root: Path, log_path: Path):
    """
    Rename directories to sanitized names, processing from deepest to shallowest.
    Keeps a map of performed renames for rollback.
    """
    renames = []  # (old_path, new_path)
    dirs = gather_dirs_by_depth(root)
    for d in dirs:
        if d == root:
            continue  # do not rename the root itself
        rel = d.relative_to(root)
        new_name = sanitize_name(d.name)
        if new_name == d.name:
            continue
        new_parent = d.parent
        new_path = new_parent / new_name
        # avoid renaming to a path that already exists: pick unique
        if new_path.exists():
            # if existing path is exactly the same target (maybe already renamed), skip
            if new_path.samefile(d):
                continue
            new_path = unique_path(new_path)
        try:
            d.rename(new_path)
            write_log(log_path, f"RENAMED_DIR: {d} -> {new_path}")
            renames.append((d, new_path))
        except Exception as ex:
            write_log(log_path, f"ERROR_RENAMING_DIR: {d} -> {new_path}  : {ex}")
            # On failure, attempt a rollback of already done renames
            try:
                for old, new in reversed(renames):
                    if new.exists():
                        new.rename(old)
                        write_log(log_path, f"ROLLBACK_DIR: {new} -> {old}")
            except Exception as rb_ex:
                write_log(log_path, f"ERROR_ROLLBACK: {rb_ex}")
            raise
    return renames

def process_files_in_leaf_dirs(root: Path, tmp_root: Path, log_path: Path):
    """
    For each directory that contains files, create new names for allowed extensions
    using grandfather_father_nr_root_0001.ext pattern and move via tmp folder.
    """
    # Walk directories (topdown True is fine), but we will process directories that contain files.
    for dirpath, dirnames, filenames in os.walk(root):
        dirp = Path(dirpath)
        # skip tmp folder if discovered under root
        if dirp == tmp_root or tmp_root in dirp.parents:
            continue

        # filter files by allowed extensions
        files = [f for f in filenames if Path(f).suffix.lower() in ALLOWED_EXTS]
        if not files:
            continue

        # natural sort of filenames
        files_sorted = sorted(files, key=natural_key)

        # find ancestor names (grandfather, father, rootname)
        # parent chain: dirp (rootname for this file set), dirp.parent (father), dirp.parent.parent (grandfather)
        rootname = sanitize_name(dirp.name) if dirp.name else 'x'
        father = sanitize_name(dirp.parent.name) if dirp.parent and dirp.parent != root else sanitize_name(dirp.parent.name) if dirp.parent else 'x'
        grandfather = 'x'
        try:
            if dirp.parent and dirp.parent.parent:
                grandfather = sanitize_name(dirp.parent.parent.name)
            else:
                grandfather = 'x'
        except Exception:
            grandfather = 'x'

        # prepare tmp subdir
        tmp_sub = tmp_root / "_files_" / Path(dirp).relative_to(root)
        tmp_sub.mkdir(parents=True, exist_ok=True)

        # create mapping old->new (in tmp)
        mappings = []
        seq = 1
        for fname in files_sorted:
            old_path = dirp / fname
            ext = old_path.suffix.lower()
            new_base = f"{grandfather}_{father}_nr_{rootname}_{seq:04d}"
            new_name = f"{new_base}{ext}"
            # sanitize final name as well (but keep underscores etc)
            new_name = sanitize_name(new_base) + ext
            tmp_target = tmp_sub / new_name
            # if new name already equals old name (after sanitization), skip
            if old_path.name == new_name:
                write_log(log_path, f"SKIP_ALREADY_OK: {old_path}")
                seq += 1
                continue
            # ensure tmp target unique
            tmp_target_unique = unique_path(tmp_target)
            try:
                # copy file to tmp (not move; safer). Use copy2 to preserve metadata if possible.
                shutil.copy2(old_path, tmp_target_unique)
                write_log(log_path, f"COPIED_TO_TMP: {old_path} -> {tmp_target_unique}")
                mappings.append((old_path, tmp_target_unique))
            except Exception as ex:
                write_log(log_path, f"ERROR_COPY_TO_TMP: {old_path} -> {tmp_target_unique} : {ex}")
                # do not abort entire run; skip this file
            seq += 1

        # After copying all files for this dir, move from tmp back to dir (final rename)
        # But to avoid overwriting, move to unique names if needed.
        for old_path, tmp_file in mappings:
            final_target = old_path.parent / tmp_file.name
            if final_target.exists():
                # If a file with same name exists, make unique
                final_target = unique_path(final_target)
            try:
                # atomic move
                tmp_file.replace(final_target)
                # remove original old file if still exists and name differs
                if old_path.exists():
                    try:
                        old_path.unlink()
                        write_log(log_path, f"REMOVED_OLD: {old_path}")
                    except Exception as exrm:
                        write_log(log_path, f"WARNING_CANNOT_REMOVE_OLD: {old_path} : {exrm}")
                write_log(log_path, f"REPLACED: {tmp_file} -> {final_target}")
            except Exception as ex:
                write_log(log_path, f"ERROR_FINAL_MOVE: {tmp_file} -> {final_target} : {ex}")
                # try to cleanup tmp
                try:
                    if tmp_file.exists():
                        tmp_file.unlink()
                except Exception:
                    pass

        # after processing, attempt to remove tmp_sub if empty
        try:
            if tmp_sub.exists() and not any(tmp_sub.iterdir()):
                tmp_sub.rmdir()
        except Exception:
            pass

def main():
    parser = argparse.ArgumentParser(description="Fix folder names and rename image/pdf files per HLA rules.")
    parser.add_argument('root', nargs='?', help='Root folder to process')
    args = parser.parse_args()

    # Determine root
    if args.root:
        root = Path(args.root).expanduser().resolve()
    else:
        # interactive: ask whether to run in current directory
        cwd = Path.cwd()
        ans = input(f"No path provided. Run in current directory '{cwd}'? (y/n): ").strip().lower()
        if ans != 'y':
            print("Aborting: no path confirmed.")
            return
        root = cwd

    if not root.exists() or not root.is_dir():
        print(f"ERROR: path does not exist or is not a directory: {root}")
        return

    # prepare log
    log_name = f"{LOG_PREFIX}{nowstr()}.log"
    log_path = root / log_name
    write_log(log_path, f"START root={root}")

    # Check max relative depth
    ok = check_max_relative_depth(root, log_path)
    if not ok:
        print(f"ABORT: found deeper folder depth than allowed ({MAX_RELATIVE_DEPTH}). See log: {log_path}")
        return

    # create tmp root
    tmp_root = root / f"{TMP_DIR_PREFIX}{os.getpid()}"
    try:
        tmp_root.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        # extremely rare, include pid to avoid race
        tmp_root = root / f"{TMP_DIR_PREFIX}{os.getpid()}_{nowstr('%f')}"
        tmp_root.mkdir(parents=True, exist_ok=True)
    write_log(log_path, f"TEMP_DIR_CREATED: {tmp_root}")

    # Step 1: rename directories safely (deepest first), keep renames for rollback
    try:
        renames = rename_directories_safe(root, log_path)
    except Exception as ex:
        write_log(log_path, f"FATAL_ERROR_RENAMING_DIRS: {ex}")
        # cleanup tmp and exit
        try:
            shutil.rmtree(tmp_root)
        except Exception:
            pass
        print(f"FATAL: error renaming directories. See log: {log_path}")
        return

    # Step 2: rescan and process files
    try:
        process_files_in_leaf_dirs(root, tmp_root, log_path)
    except Exception as ex:
        write_log(log_path, f"ERROR_PROCESSING_FILES: {ex}")
        # Do not rollback folder renames here automatically (dangerous); user can review log and revert if needed.
        print(f"ERROR during file processing. See log: {log_path}")

    # cleanup tmp
    try:
        if tmp_root.exists():
            shutil.rmtree(tmp_root)
            write_log(log_path, f"TEMP_DIR_REMOVED: {tmp_root}")
    except Exception as ex:
        write_log(log_path, f"WARNING_CANNOT_REMOVE_TMP: {tmp_root} : {ex}")

    write_log(log_path, "FINISHED")
    print(f"Done. See log for details: {log_path}")

if __name__ == "__main__":
    main()
