#!/usr/bin/env python3
"""
archive_clean_and_rename.py
version: 2.4
Author: Mustafa Demiroglu

A safe, cross-platform script for archival file organization that:
  1. Fixes folder names according to HLA naming standards
  2. Renames image/pdf files in leaf folders using the pattern:
        grandfather_father_nr_root_0001.ext
  3. Logs all operations to a timestamped log file
  4. Supports DRY-RUN mode to preview changes without modifying files
  5. Shows live progress with 4 progress bars:
        [GENERAL]   - Overall progress (all files + directories)
        [ARCHIVE]   - Archive-level directory progress
        [BESTAND]   - Bestand-level directory progress
        [SIGNATUR]  - Individual file processing progress

Usage:
    python3 archive_clean_and_rename.py /path/to/root
    python3 archive_clean_and_rename.py -n /path/to/root
    python3 archive_clean_and_rename.py        # prompts to use current directory

Arguments:
    -n, --dry-run    Preview all operations without making any changes

Safety Features:
    - Root directory itself is never renamed
    - Aborts if any file is deeper than MAX_RELATIVE_DEPTH levels
    - Creates temporary directory under root for safe file operations
    - Provides rollback mechanism for both folder and file operations
    - Allowed extensions: .tif, .tiff, .jpg, .jpeg, .png, .pdf (case-insensitive)
    - Removes commas and sanitizes all names per HLA standards
    - All disallowed characters are automatically removed or substituted
    - Temporary folder '._tmp_archive_renamer_<pid>' is cleaned up at the end

"""
import argparse
import sys
import os
import shutil
import re
from pathlib import Path
from datetime import datetime
import unicodedata

from rich.progress import Progress, BarColumn, TextColumn, TimeRemainingColumn

# ==============================
# CONFIGURATION
# ==============================
ALLOWED_EXTS = {'.tif', '.tiff', '.jpg', '.jpeg', '.png', '.pdf'}
MAX_RELATIVE_DEPTH = 4  # Maximum allowed directory depth relative to root

TMP_DIR_PREFIX = "._tmp_archive_renamer_"
LOG_PREFIX = "archive_rename_log_"

# Compiled regex for name sanitization (allows only: a-z, 0-9, dot, underscore, hyphen)
_ALLOWED_NAME_RE = re.compile(r'[^a-z0-9._-]')


# ==============================
# UTILITY FUNCTIONS
# ==============================
def nowstr(fmt="%Y%m%d_%H%M%S"):
    """Returns current timestamp as formatted string."""
    return datetime.now().strftime(fmt)


def write_log(log_path: Path, line: str, dry=False):
    """
    Appends a timestamped log entry to the log file.
    
    Args:
        log_path: Path to the log file
        line: Log message to write
        dry: If True, prefixes message with "DRY: "
    """
    prefix = "DRY: " if dry else ""
    with log_path.open("a", encoding="utf-8") as f:
        f.write(f"{datetime.now().isoformat()}  {prefix}{line}\n")


def natural_key(s: str):
    """
    Generates a key for natural sorting (e.g., 'file2' before 'file10').
    
    Args:
        s: String to create sort key for
        
    Returns:
        List of mixed integers and lowercase strings for sorting
    """
    parts = re.split(r'(\d+)', s)
    out = []
    for p in parts:
        out.append(int(p) if p.isdigit() else p.lower())
    return out


def sanitize_name(name: str) -> str:
    """
    Sanitizes a name according to HLA naming standards:
    - Converts to lowercase
    - Replaces German umlauts (ä→ae, ö→oe, ü→ue, ß→ss)
    - Converts '/' to '--' and '+' to '..'
    - Replaces whitespace with '_'
    - Removes commas completely
    - Removes all other disallowed characters
    - Removes leading zeros from pure numeric names
    
    Args:
        name: Original name to sanitize
        
    Returns:
        Sanitized name safe for filesystem use
    """
    original = name
    # Normalize unicode characters
    name = unicodedata.normalize('NFKD', name)
    name = name.lower()

    # Replace German special characters
    name = name.replace('ä', 'ae').replace('ö', 'oe').replace('ü', 'ue').replace('ß', 'ss')
    
    # Replace special path characters
    name = name.replace('/', '--')
    name = name.replace('+', '..')
    
    # Replace whitespace with underscore
    name = re.sub(r'\s+', '_', name)
    
    # Remove commas completely
    name = name.replace(',', '')

    # Remove all other disallowed characters
    name = _ALLOWED_NAME_RE.sub('', name)
    
    # Collapse multiple consecutive special characters
    name = re.sub(r'[_]{2,}', '_', name)
    name = re.sub(r'[.]{2,}', '..', name)
    name = re.sub(r'[-]{2,}', '--', name)

    # Remove leading/trailing special characters
    name = name.strip('._-')

    # Remove leading zeros from pure numeric names
    if name.isdigit():
        try:
            name = str(int(name))
        except:
            pass

    # Return 'x' if name becomes empty after sanitization
    return name if name else 'x'


def unique_path(target: Path, max_attempts: int = 99) -> Path:
    """
    Generates a unique path by appending _dup1, _dup2, etc. if target exists.
    
    Args:
        target: Desired target path
        max_attempts: Maximum number of duplicate attempts (default: 99)
        
    Returns:
        A unique Path that doesn't exist yet
        
    Raises:
        RuntimeError: If no unique path found within max_attempts
    """
    if not target.exists():
        return target
    
    base, ext = target.stem, target.suffix
    parent = target.parent
    
    for i in range(1, max_attempts + 1):
        candidate = parent / f"{base}_dup{i}{ext}"
        if not candidate.exists():
            return candidate
    
    # If we've exhausted all attempts, raise an error
    raise RuntimeError(f"Could not find unique path for {target} after {max_attempts} attempts")


# ==============================
# DEPTH CHECK
# ==============================
def check_max_relative_depth(root: Path, log_path: Path) -> bool:
    """
    Checks that no file is deeper than MAX_RELATIVE_DEPTH relative to root.
    
    Args:
        root: Root directory path
        log_path: Path to log file
        
    Returns:
        True if all files are within depth limit, False otherwise
    """
    max_depth = 0
    for p in root.rglob("*"):
        if p.is_file():
            depth = len(p.parent.relative_to(root).parts)
            max_depth = max(max_depth, depth)

    write_log(log_path, f"Maximum depth found: {max_depth} (limit: {MAX_RELATIVE_DEPTH})")
    return max_depth <= MAX_RELATIVE_DEPTH


# ==============================
# DIRECTORY OPERATIONS
# ==============================
def gather_dirs_by_depth(root: Path):
    """
    Collects all directories under root, sorted deepest-first.
    This allows safe renaming from bottom to top of the tree.
    
    Args:
        root: Root directory path
        
    Returns:
        Generator of Path objects sorted by depth (deepest first)
    """
    # Use generator to avoid loading all paths into memory
    dirs = (p for p in root.rglob("*") if p.is_dir())
    # Sort by depth (deepest first) for safe renaming
    return sorted(dirs, key=lambda p: len(p.relative_to(root).parts), reverse=True)


def count_directories_by_level(root: Path):
    """
    Counts directories at each hierarchy level for progress tracking.
    
    Args:
        root: Root directory path
        
    Returns:
        Tuple of (archive_count, bestand_count, signatur_count)
    """
    archive_dirs = set()  # Level 1: direct children of root
    bestand_dirs = set()  # Level 2: grandchildren of root
    signatur_dirs = set() # Level 3: great-grandchildren of root
    
    for p in root.rglob("*"):
        if not p.is_dir():
            continue
        
        try:
            rel_parts = p.relative_to(root).parts
            depth = len(rel_parts)
            
            if depth == 1:
                archive_dirs.add(p)
            elif depth == 2:
                bestand_dirs.add(p)
            elif depth == 3:
                signatur_dirs.add(p)
        except ValueError:
            # Path is not relative to root, skip it
            continue
    
    return len(archive_dirs), len(bestand_dirs), len(signatur_dirs)


def rename_directories_safe(root: Path, log_path: Path, dry: bool, progress, 
                            general_task, archive_task, bestand_task, signatur_task):
    """
    Renames all directories according to HLA standards, with rollback on error.
    
    Args:
        root: Root directory path
        log_path: Path to log file
        dry: If True, only simulates operations
        progress: Rich progress instance
        general_task: General progress task ID
        archive_task: Archive-level progress task ID
        bestand_task: Bestand-level progress task ID
        signatur_task: Signatur-level progress task ID
        
    Returns:
        List of (old_path, new_path) tuples for renamed directories
    """
    renames = []
    dirs = gather_dirs_by_depth(root)

    for d in dirs:
        # Update general progress for each directory processed
        progress.advance(general_task)

        # Don't rename the root directory itself
        if d == root:
            continue

        # Calculate sanitized name
        new_name = sanitize_name(d.name)
        if new_name == d.name:
            continue  # No change needed

        new_path = d.parent / new_name
        
        # Handle name conflicts
        if new_path.exists() and not dry and not new_path.samefile(d):
            try:
                new_path = unique_path(new_path)
            except RuntimeError as e:
                write_log(log_path, f"ERROR: {e}")
                # Rollback all previous renames
                for old, new in reversed(renames):
                    try:
                        if new.exists():
                            new.rename(old)
                            write_log(log_path, f"ROLLBACK: {new} -> {old}")
                    except Exception as rb:
                        write_log(log_path, f"ERROR_ROLLBACK: {rb}")
                raise

        # Dry run: only log what would happen
        if dry:
            write_log(log_path, f"Would rename directory: {d} -> {new_path}", dry=True)
            continue

        # Perform the actual rename
        try:
            d.rename(new_path)
            write_log(log_path, f"RENAMED_DIR: {d} -> {new_path}")
            renames.append((d, new_path))
            
            # Update appropriate progress bar based on depth
            try:
                rel_parts = new_path.relative_to(root).parts
                depth = len(rel_parts)
                
                if depth == 1:
                    progress.advance(archive_task)
                elif depth == 2:
                    progress.advance(bestand_task)
                elif depth == 3:
                    progress.advance(signatur_task)
            except ValueError:
                pass  # Not relative to root
                
        except Exception as ex:
            write_log(log_path, f"ERROR_RENAMING_DIR: {d} -> {new_path}: {ex}")
            # Rollback all previous renames
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
# FILE OPERATIONS
# ==============================
def process_files_in_leaf_dirs(root: Path, tmp_root: Path, log_path: Path,
                               dry: bool, progress, general_task, signatur_task):
    """
    Processes and renames files in all leaf directories.
    Uses a two-step process:
      1. Copy files to temp with new names
      2. Delete originals and move files back
    This allows rollback if errors occur.
    
    Args:
        root: Root directory path
        tmp_root: Temporary directory for staging files
        log_path: Path to log file
        dry: If True, only simulates operations
        progress: Rich progress instance
        general_task: General progress task ID
        signatur_task: Signatur-level progress task ID
    """
    for dirpath, dirnames, filenames in os.walk(root):
        dirp = Path(dirpath)

        # Skip temporary directory
        if tmp_root in dirp.parents or tmp_root == dirp:
            continue

        # Filter for allowed file extensions
        files = [f for f in filenames if Path(f).suffix.lower() in ALLOWED_EXTS]
        if not files:
            continue

        # Extract hierarchy names for file naming pattern
        rootname = sanitize_name(dirp.name)
        father = sanitize_name(dirp.parent.name) if dirp.parent != root else 'x'
        grandfather = sanitize_name(dirp.parent.parent.name) if dirp.parent and dirp.parent.parent and dirp.parent.parent != root else 'x'

        # Sort files naturally (file2 before file10)
        files_sorted = sorted(files, key=natural_key)
        
        # Create temporary subdirectory for this leaf folder
        tmp_sub = tmp_root / "_files_" / dirp.relative_to(root)

        if dry:
            write_log(log_path, f"Would create temporary folder: {tmp_sub}", dry=True)
        else:
            try:
                tmp_sub.mkdir(parents=True, exist_ok=True)
            except Exception as e:
                write_log(log_path, f"ERROR_CREATE_TMP_DIR: {tmp_sub}: {e}")
                continue

        mappings = []  # Track (original, temp_copy) for rollback
        seq = 1

        # Step 1: Copy all files to temp with new names
        for fname in files_sorted:
            progress.advance(general_task)
            progress.advance(signatur_task)

            old_path = dirp / fname
            ext = old_path.suffix.lower()

            # Generate new filename: grandfather_father_nr_rootname_0001.ext
            new_base = f"{grandfather}_{father}_nr_{rootname}_{seq:04d}"
            new_name = sanitize_name(new_base) + ext
            tmp_target = tmp_sub / new_name

            if dry:
                write_log(log_path, f"Would copy: {old_path} -> {tmp_target}", dry=True)
                mappings.append((old_path, tmp_target))
                seq += 1
                continue

            try:
                # Ensure unique temp filename
                tmp_target_u = unique_path(tmp_target)
                shutil.copy2(old_path, tmp_target_u)
                mappings.append((old_path, tmp_target_u))
                write_log(log_path, f"COPIED: {old_path} -> {tmp_target_u}")
            except RuntimeError as e:
                write_log(log_path, f"ERROR_UNIQUE_PATH: {tmp_target}: {e}")
                # Rollback: delete all copied files in this directory
                for _, tmp_file in mappings:
                    try:
                        if tmp_file.exists():
                            tmp_file.unlink()
                            write_log(log_path, f"ROLLBACK_DELETE: {tmp_file}")
                    except Exception as rb:
                        write_log(log_path, f"ERROR_ROLLBACK_DELETE: {tmp_file}: {rb}")
                break
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
                break

            seq += 1

        # Step 2: Move files from temp to final location
        for old_path, tmp_file in mappings:
            final_target = old_path.parent / tmp_file.name

            if dry:
                write_log(log_path, f"Would move: {tmp_file} -> {final_target}", dry=True)
                continue

            # Delete original file if it still exists
            if old_path.exists():
                try:
                    old_path.unlink()
                    write_log(log_path, f"DELETED_ORIGINAL: {old_path}")
                except Exception as e:
                    write_log(log_path, f"ERROR_DELETE_ORIGINAL: {old_path}: {e}")
                    continue

            # Handle existing file at final target
            if final_target.exists():
                try:
                    final_target.unlink()
                except Exception as e:
                    write_log(log_path, f"ERROR_DELETE_EXISTING: {final_target}: {e}")
                    try:
                        final_target = unique_path(final_target)
                    except RuntimeError as re:
                        write_log(log_path, f"ERROR_UNIQUE_PATH_FINAL: {final_target}: {re}")
                        continue

            # Move file from temp to final location
            try:
                tmp_file.replace(final_target)
                write_log(log_path, f"RENAMED_FILE: {old_path.name} -> {final_target.name}")
            except Exception as ex:
                write_log(log_path, f"ERROR_MOVE_FINAL: {tmp_file} -> {final_target}: {ex}")

        # Clean up empty temporary subdirectory
        if not dry:
            try:
                if tmp_sub.exists() and not any(tmp_sub.iterdir()):
                    tmp_sub.rmdir()
            except Exception as e:
                write_log(log_path, f"ERROR_REMOVE_TMP_SUB: {tmp_sub}: {e}")


# ==============================
# MAIN ENTRY POINT
# ==============================
def main():
    """
    Main execution function.
    Parses arguments, validates input, and orchestrates the renaming process.
    """
    parser = argparse.ArgumentParser(
        description="HLA archival file organization and renaming tool.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s /path/to/archive
  %(prog)s -n /path/to/archive        (dry run - no changes made)
  %(prog)s                            (prompts to use current directory)
        """
    )
    parser.add_argument("root", nargs="?", help="Root directory to process")
    parser.add_argument("-n", "--dry-run", action="store_true", 
                       help="Simulate all operations without making any changes")
    args = parser.parse_args()
    dry = args.dry_run

    # Determine root directory
    if args.root:
        root = Path(args.root).expanduser().resolve()
    else:
        ans = input(f"No path specified. Use current directory '{Path.cwd()}'? (y/n): ").lower().strip()
        if ans != 'y':
            print("Operation cancelled.")
            return
        root = Path.cwd()

    if not root.exists():
        print(f"Error: Path does not exist: {root}")
        return
    
    if not root.is_dir():
        print(f"Error: Path is not a directory: {root}")
        return

    # Create log file
    log_path = root / f"{LOG_PREFIX}{nowstr()}.log"
    write_log(log_path, f"=== START === root={root} dry_run={dry}")

    # Safety check: verify directory depth
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
    # For GENERAL: count all directories + all allowed files
    total_dirs = sum(1 for _ in root.rglob("*") if _.is_dir())
    total_files = sum(1 for _ in root.rglob("*") if _.is_file() and _.suffix.lower() in ALLOWED_EXTS)
    total_general = max(total_dirs + total_files, 1)
    
    # For hierarchy levels: count directories at each level
    archive_count, bestand_count, signatur_count = count_directories_by_level(root)
    
    write_log(log_path, f"Progress totals - General: {total_general}, Archive: {archive_count}, "
                       f"Bestand: {bestand_count}, Signatur: {signatur_count}")

    # Create progress bars
    try:
        with Progress(
            TextColumn("[bold blue]{task.description}"),
            BarColumn(),
            TextColumn("[progress.percentage]{task.percentage:>3.0f}%"),
            TimeRemainingColumn(),
        ) as progress:

            # Four permanent progress bars shown to user
            general_task = progress.add_task("[white]GENERAL", total=total_general)
            archive_task = progress.add_task("[cyan]ARCHIVE", total=max(archive_count, 1))
            bestand_task = progress.add_task("[green]BESTAND", total=max(bestand_count, 1))
            signatur_task = progress.add_task("[yellow]SIGNATUR", total=max(signatur_count, 1))

            # Phase 1: Rename directories
            write_log(log_path, "Phase 1: Renaming directories")
            rename_directories_safe(root, log_path, dry, progress, 
                                   general_task, archive_task, bestand_task, signatur_task)
            
            # Phase 2: Process files
            write_log(log_path, "Phase 2: Processing files")
            process_files_in_leaf_dirs(root, tmp_root, log_path, dry, progress, 
                                      general_task, signatur_task)

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
                            p.rmdir()
                    except Exception as e2:
                        write_log(log_path, f"ERROR_MANUAL_CLEANUP: {p}: {e2}")
                tmp_root.rmdir()
                write_log(log_path, f"Manually removed temporary directory: {tmp_root}")
            except Exception as e3:
                write_log(log_path, f"ERROR_FINAL_CLEANUP: {e3}")
                print(f"Warning: Could not remove temporary directory: {tmp_root}")
                print("You may need to remove it manually.")

    write_log(log_path, "=== FINISHED ===")
    print(f"\nOperation completed successfully.")
    print(f"Log file: {log_path}")


if __name__ == "__main__":
    main()