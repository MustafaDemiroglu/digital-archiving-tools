#!/usr/bin/env python3
"""
archive_clean_and_rename.py
version: 4.0
Author: Mustafa Demiroglu

Simple, safe, cross-platform script to:
  1. Fix folder names according to HLA “Benennungsrichtlinie”
  2. Then rename image/pdf files in the leaf folders using:
        grandfather_father_nr_root_0001.ext
  3. Log all actions
  4. Support DRY-RUN mode to simulate everything without making changes
  5.Live progress bars (rich) showing ONLY active operations:
        [GENERAL]
        [ARCHIVE]
        [BESTAND]
        [SIGNATUR]

Usage:
    python3 archive_clean_and_rename.py /path/to/root
    python3 archive_clean_and_rename.py -n /path/to/root
    python3 archive_clean_and_rename.py        # asks to use current directory

Arguments:
    -n, --dry-run    simulate all actions; do NOT modify anything

Notes / safety:
    - Does NOT rename the root directory
    - If any file is deeper than MAX_RELATIVE_DEPTH under root → abort
    - Temporary directory is created under root (except in DRY-RUN)
    - Folder rename rollback is attempted only when not in dry-run
    - Allowed file extensions: .tif, .tiff, .jpg, .jpeg, .png, .pdf (case-insensitive)
    - If any file under the target root has relative directory depth > 4, the script aborts.
    - Temporary folder '_tmp_archive_renamer_<pid>' is created inside the root and removed at end.
    - Commas (',') are removed from names (per your specification).
    - All other disallowed characters are removed.
    - If a fatal error happens during folder renaming, the script tries to rollback changes.

"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import unicodedata
from datetime import datetime
from pathlib import Path
from typing import List, Tuple

from rich.progress import Progress, BarColumn, TextColumn, TimeRemainingColumn

# ==============================
# CONFIG
# ==============================
ALLOWED_EXTS = {'.tif', '.tiff', '.jpg', '.jpeg', '.png', '.pdf'}
MAX_RELATIVE_DEPTH = 4
TMP_DIR_PREFIX = "tmp_archive_renamer_"
LOG_PREFIX = "archive_rename_log_"
_ALLOWED_NAME_RE = re.compile(r'[^a-z0-9._-]')


# ==============================
# UTILS
# ==============================

def nowstr(fmt: str = "%Y%m%d_%H%M%S") -> str:
    return datetime.now().strftime(fmt)


def write_log(log_path: Path, line: str, dry: bool = False) -> None:
    prefix = "DRY: " if dry else ""
    with log_path.open("a", encoding="utf-8") as f:
        f.write(f"{datetime.now().isoformat()}  {prefix}{line}\n")


def natural_key(s: str):
    parts = re.split(r"(\d+)", s)
    out = []
    for p in parts:
        out.append(int(p) if p.isdigit() else p.lower())
    return out


def sanitize_name(name: str) -> str:
    """Apply normalization rules and return a filesystem-safe name.

    If the result is empty, returns 'x'.
    """
   #1name = unicodedata.normalize('NFKD', name)
   #2name = unicodedata.normalize('NFKD', name)
    name = unicodedata.normalize('NFC', name)
    name = name.lower()

   #1name = name.replace('a¨', 'ae').replace('o¨', 'oe').replace('u¨', 'ue')
   #2name = name.replace('¨', 'e')

    name = name.replace('ä', 'ae').replace('ö', 'oe').replace('ü', 'ue').replace('ß', 'ss')  
    name = name.replace('/', '--')
    name = name.replace('+', '..')
    name = re.sub(r'\s+', '_', name)
    name = name.replace(',', '')

    name = _ALLOWED_NAME_RE.sub('', name)
    name = re.sub(r'[_]{2,}', '_', name)
    name = re.sub(r'[.]{2,}', '..', name)
    name = re.sub(r'[-]{2,}', '--', name)

    name = name.strip('._-')

    # Remove leading zeros from any numeric segment (global)
    # e.g. 001013_ay -> 1013_ay ; ayd_001014 -> ayd_1014 ; '000' -> '0'
    def _strip_leading_zeros(match: re.Match) -> str:
        s = match.group(0)
        try:
            return str(int(s))
        except Exception:
            return s  # fallback, should not happen

    name = re.sub(r'\d+', _strip_leading_zeros, name)

    return name if name else 'x'


def unique_path(target: Path, max_attempts: int = 9) -> Path:
    """Return a non-existing Path based on target by appending _dupN if needed."""
    if not target.exists():
        return target
    base = target.stem
    ext = target.suffix
    parent = target.parent

    for i in range(1, max_attempts + 1):
        candidate = parent / f"{base}_dup{i}{ext}"
        if not candidate.exists():
            return candidate

    raise RuntimeError(f"Could not find unique path for {target} after {max_attempts} attempts")


# ==============================
# DEPTH CHECK
# ==============================

def check_max_relative_depth(root: Path, log_path: Path) -> bool:
    max_depth = 0
    for p in root.rglob("*"):
        if p.is_file():
            try:
                depth = len(p.parent.relative_to(root).parts)
            except Exception:
                depth = 0
            max_depth = max(max_depth, depth)

    write_log(log_path, f"Max depth found = {max_depth}")
    return max_depth <= MAX_RELATIVE_DEPTH


# ==============================
# DIRECTORY RENAME
# ==============================

def gather_dirs_by_depth(root: Path) -> List[Path]:
    dirs = [p for p in root.rglob("*") if p.is_dir()]
    dirs.append(root)
    return sorted(dirs, key=lambda p: len(p.relative_to(root).parts), reverse=True)


def rename_directories_safe(root: Path, log_path: Path, dry: bool, progress: Progress, general_task: int):
    renames: List[Tuple[Path, Path]] = []
    dirs = gather_dirs_by_depth(root)

    for d in dirs:
        progress.advance(general_task)

        if d == root:
            continue

        new_name = sanitize_name(d.name)
        if new_name == d.name:
            continue

        new_path = d.parent / new_name
        if new_path.exists() and not dry:
            try:
                # samefile can raise if files don't exist or on some platforms; guard it
                if not new_path.exists() or not new_path.samefile(d):
                    new_path = unique_path(new_path)
            except Exception:
                # fallback to unique_path
                new_path = unique_path(new_path)

        if dry:
            write_log(log_path, f"Would rename dir: {d} -> {new_path}", dry=True)
            continue

        try:
            d.rename(new_path)
            write_log(log_path, f"RENAMED_DIR: {d} -> {new_path}")
            renames.append((d, new_path))
        except Exception as ex:
            write_log(log_path, f"ERROR_RENAMING_DIR: {d} -> {new_path}: {ex}")
            # rollback
            for old, new in reversed(renames):
                try:
                    if new.exists():
                        new.rename(old)
                        write_log(log_path, f"ROLLBACK: {new} -> {old}")
                except Exception as rb:
                    write_log(log_path, f"ERROR_ROLLBACK: {rb}")
            raise

    return renames


# ==============================
# FILE PROCESSING WITH CORRECT PROGRESS BARS
# ==============================

def process_files_in_leaf_dirs(root: Path, tmp_root: Path, log_path: Path,
                               dry: bool, progress: Progress, general_task: int) -> None:

    for dirpath, dirnames, filenames in os.walk(root):
        dirp = Path(dirpath)

        if tmp_root in dirp.parents:
            continue

        files = [f for f in filenames if Path(f).suffix.lower() in ALLOWED_EXTS]
        if not files:
            continue

        # Identify names
        rootname = sanitize_name(dirp.name)
        father = sanitize_name(dirp.parent.name) if dirp.parent and dirp.parent != root else 'x'
        grandfather = sanitize_name(dirp.parent.parent.name) if dirp.parent and dirp.parent.parent and dirp.parent.parent != root else 'x'

        # Correct progress total
        files_sorted = sorted(files, key=natural_key)
        signatur_total = len(files_sorted)
        task_label = f"[yellow]{grandfather}/{father}/{rootname}"
        signatur_task = progress.add_task(task_label, total=signatur_total)

        tmp_sub = tmp_root / "_files_" / dirp.relative_to(root)

        if dry:
            write_log(log_path, f"Would create tmp folder: {tmp_sub}", dry=True)
        else:
            tmp_sub.mkdir(parents=True, exist_ok=True)

        mappings: List[Tuple[Path, Path]] = []
        seq = 1

        for fname in files_sorted:
            progress.advance(general_task)
            progress.advance(signatur_task)

            old_path = dirp / fname
            ext = old_path.suffix.lower()

            new_base = f"{grandfather}_{father}_nr_{rootname}_{seq:04d}"
            new_name = new_base + ext
            tmp_target = tmp_sub / new_name

            if dry:
                write_log(log_path, f"Would copy {old_path} -> {tmp_target}", dry=True)
                mappings.append((old_path, tmp_target))
                seq += 1
                continue

            try:
                tmp_target_u = unique_path(tmp_target)
                shutil.copy2(old_path, tmp_target_u)
                mappings.append((old_path, tmp_target_u))
                write_log(log_path, f"COPIED: {old_path} -> {tmp_target_u}")
            except Exception as ex:
                write_log(log_path, f"ERROR_COPY: {old_path}: {ex}")
                # Rollback: delete all copied files in this directory
                for _, tmp_file in mappings:
                    try:
                        if tmp_file.exists():
                            tmp_file.unlink()
                            write_log(log_path, f"ROLLBACK_DELETE: {tmp_file}")
                    except Exception as rb:
                        write_log(log_path, f"ERROR_ROLLBACK_DELETE: {tmp_file}: {rb}")
                # abort processing this folder
                mappings = []
                break

            seq += 1

        # Final rename/move: use atomic replace when possible
        for old_path, tmp_file in mappings:
            final_target = old_path.parent / tmp_file.name

            if dry:
                write_log(log_path, f"Would move {tmp_file} -> {final_target}", dry=True)
                continue

            try:
                # Try atomic replace which will overwrite final_target if it exists
                tmp_file.replace(final_target)
                write_log(log_path, f"RENAMED_FILE: {old_path} -> {final_target}")
                # After successful move, remove the original old_path (if different)
                try:
                    # If final_target and old_path are the same path, do NOT unlink,
                    # because final_target now refers to the new file. Only unlink old_path if it still exists and is a different path.
                    if old_path.exists() and (old_path.resolve() != final_target.resolve()):
                        old_path.unlink()
                        write_log(log_path, f"REMOVED_OLD_FILE: {old_path}")
                except Exception as del_ex:
                    write_log(log_path, f"ERROR_REMOVING_OLD_FILE: {old_path}: {del_ex}")
            except Exception as ex:
                write_log(log_path, f"ERROR_MOVE: {tmp_file} -> {final_target}: {ex}")
                # try alternative: unique final target
                try:
                    alt = unique_path(final_target)
                    tmp_file.replace(alt)
                    write_log(log_path, f"RENAMED_FILE_ALT: {old_path} -> {alt}")
                    try:
                        if old_path.exists() and (old_path.resolve() != alt.resolve()):
                            old_path.unlink()
                            write_log(log_path, f"REMOVED_OLD_FILE: {old_path}")
                    except Exception as del_ex:
                        write_log(log_path, f"ERROR_REMOVING_OLD_FILE_AFTER_ALT: {old_path}: {del_ex}")
                except Exception as ex2:
                    write_log(log_path, f"FAILED_MOVE_ALT: {tmp_file} -> {final_target}: {ex2}")

        # Remove tmp_sub if empty
        if not dry:
            try:
                if tmp_sub.exists() and not any(tmp_sub.iterdir()):
                    tmp_sub.rmdir()
            except Exception as e:
                write_log(log_path, f"ERROR_REMOVE_TMP_SUB: {tmp_sub}: {e}")

        progress.remove_task(signatur_task)


# ==============================
# MAIN
# ==============================

def main() -> None:
    parser = argparse.ArgumentParser(
        description="HLA archival file organization and renaming tool.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
                    Examples:
                      %(prog)s /path/to/archive
                      %(prog)s -n /path/to/archive        (dry run - no changes made)
                      %(prog)s                            (prompts to use current directory)
                            """,
    )
    parser.add_argument("root", nargs="?", help="Root directory to process")
    parser.add_argument("-n", "--dry-run", action="store_true", help="Simulate all operations without making any changes")
    args = parser.parse_args()
    dry = args.dry_run

    # Determine root
    if args.root:
        root = Path(args.root).expanduser().resolve()
    else:
        ans = input(f"No path given. Run in current directory '{Path.cwd()}'? (y/n): ").lower().strip()
        if ans != 'y':
            print("Aborted.")
            return
        root = Path.cwd()

    if not root.exists():
        print(f"Error: Path does not exist: {root}")
        return

    if not root.is_dir():
        print(f"Error: Path is not a directory: {root}")
        return

    # Log
    log_path = root / f"{LOG_PREFIX}{nowstr()}.log"
    write_log(log_path, f"=== START === root={root} dry_run={dry}")

    # Depth check
    if not check_max_relative_depth(root, log_path):
        print(f"ABORT: Files exceed maximum depth of {MAX_RELATIVE_DEPTH}. See log: {log_path}")
        write_log(log_path, "ABORTED: Maximum depth exceeded")
        return

    # Set up temporary directory
    if dry:
        tmp_root = root / f"{TMP_DIR_PREFIX}DRYRUN"
        write_log(log_path, f"Dry run mode: temporary directory = {tmp_root}")
    else:
        tmp_root = root / f"{TMP_DIR_PREFIX}{os.getpid()}"
        try:
            tmp_root.mkdir(exist_ok=False)
            write_log(log_path, f"Created temporary directory: {tmp_root}")
        except FileExistsError:
            print(f"Error: Temporary directory already exists: {tmp_root}")
            print("Another instance may be running. Please check and remove manually if needed.")
            write_log(log_path, f"ERROR: Temporary directory already exists: {tmp_root}")
            return
        except Exception as e:
            print(f"Error creating temporary directory: {e}")
            write_log(log_path, f"ERROR_CREATE_TMP: {e}")
            return

    # Calculate progress totals
    total_items = sum(1 for _ in root.rglob("*"))

    # PROGRESS UI + main try/except to handle KeyboardInterrupt and cleanup
    try:
        with Progress(
            TextColumn("[bold blue]{task.description}"),
            BarColumn(),
            TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
            TimeRemainingColumn(),
        ) as progress:
            # General permanent progress bar shown to user
            write_log(log_path, "Phase 1: Renaming directories")
            general_task = progress.add_task("[white]GENERAL", total=total_items)
            # Phase 1: Rename directories
            rename_directories_safe(root, log_path, dry, progress, general_task)
            # Phase 2: Process files
            write_log(log_path, "Phase 2: Processing files")
            process_files_in_leaf_dirs(root, tmp_root, log_path, dry, progress, general_task)

    except KeyboardInterrupt:
        print("\n\nOperation interrupted by user.")
        write_log(log_path, "INTERRUPTED: User cancelled operation")
        # Clean up temporary directory
        if not dry and tmp_root.exists():
            print("Cleaning up temporary files...")
            try:
                shutil.rmtree(tmp_root)
                write_log(log_path, f"Cleaned up temporary directory: {tmp_root}")
            except Exception as e:
                write_log(log_path, f"ERROR_CLEANUP_INTERRUPTED: {e}")
        return
    except Exception as e:
        print(f"\n\nFatal error: {e}")
        write_log(log_path, f"FATAL_ERROR: {e}")
        # Clean up temporary directory
        if not dry and tmp_root.exists():
            print("Cleaning up temporary files...")
            try:
                shutil.rmtree(tmp_root)
                write_log(log_path, f"Cleaned up temporary directory after error: {tmp_root}")
            except Exception as cleanup_error:
                write_log(log_path, f"ERROR_CLEANUP_AFTER_ERROR: {cleanup_error}")
        raise

    # Clean up temporary directory after successful completion
    if not dry and tmp_root.exists():
        try:
            shutil.rmtree(tmp_root)
            write_log(log_path, f"Removed temporary directory: {tmp_root}")
        except Exception as e:
            write_log(log_path, f"ERROR_CLEANUP: {e}")
            # Try manual cleanup if shutil.rmtree fails
            try:
                for p in sorted(tmp_root.rglob("*"), reverse=True):
                    try:
                        if p.is_file():
                            p.unlink()
                        else:
                            # attempt to remove empty dirs only
                            try:
                                p.rmdir()
                            except OSError:
                                # directory not empty, skip
                                pass
                    except Exception as e2:
                        write_log(log_path, f"ERROR_MANUAL_CLEANUP: {p}: {e2}")
                # try removing tmp_root itself
                try:
                    tmp_root.rmdir()
                    write_log(log_path, f"Manually removed temporary directory: {tmp_root}")
                except Exception as e_inner:
                    write_log(log_path, f"ERROR_MANUAL_RMDIR_TMP_ROOT: {tmp_root}: {e_inner}")
            except Exception as e3:
                write_log(log_path, f"ERROR_FINAL_CLEANUP: {e3}")
                print(f"Warning: Could not remove temporary directory: {tmp_root}")
                print("You may need to remove it manually.")

    write_log(log_path, "=== FINISHED ===")
    print(f"\nOperation completed successfully.")
    print(f"Log file: {log_path}")


if __name__ == "__main__":
    main()