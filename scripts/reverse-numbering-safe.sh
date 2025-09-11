#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# reverse-numbering-safe.sh 
# version 1.2
# Author : Mustafa Demiroglu
#
# Description:
#   This script reverses the numeric suffix order of files that share a common
#   prefix and extension inside a target directory. Example:
#     hstam_115--11_nr_418_0001.tif ... hstam_115--11_nr_418_0039.tif
#   After running, 0001 becomes 0039, 0002 becomes 0038, etc.
#
# Safety / algorithm:
#   1. The script asks the user for PREFIX and EXT (extension without dot).
#   2. It detects all files matching PREFIX*.EXT and keeps only those whose
#      suffix (between prefix and extension) is strictly numeric.
#   3. It computes numeric ordering and the required zero-padding (keeps
#      original padding width, but ensures padding is at least wide enough for
#      the number of files).
#   4. To avoid collisions/overwrites (e.g. renaming 0039 -> 0001 while 0001
#      still exists), the script moves all original files into a temporary
#      directory (inside the target directory) and renames them *inside* that
#      temp directory to their final (reversed) names.
#   5. After all renamed files live in the temp directory, they are moved back
#      to the target directory in a safe manner.
#   6. The empty temporary directory is removed at the end.
#
# Features:
#   - Interactive prompts for PREFIX and EXT (so you can reuse the same script).
#   - Optional TARGET_DIR as an argument (if omitted you will be prompted).
#   - --dry-run / -n : simulate actions without performing moves.
#   - --verbose / -v : print detailed progress.
#   - Basic safety checks for existing destination files (script aborts if a
#     final destination already exists).
#
# Notes:
#   - The script works best when run in an environment with standard GNU tools.
#   - Filenames with whitespace are supported; however, filenames that include
#     literal tabs may cause issues (separator used internally is tab).
#
# -----------------------------------------------------------------------------

usage() {
  cat <<USAGE
Usage: $0 [OPTIONS] [TARGET_DIR]

Options:
  -n, --dry-run     Do not perform any moves; only print what would happen.
  -v, --verbose     Print detailed progress messages.
  -h, --help        Show this help.

If TARGET_DIR is not provided, you will be prompted (default: current directory).
The script will then prompt for PREFIX and EXT (extension without dot).
USAGE
}

# Parse options
DRY_RUN=0
VERBOSE=0
TARGET_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) TARGET_DIR="$1"; shift; break ;;
  esac
done

# Prompt for target directory if not provided
if [[ -z "${TARGET_DIR}" ]]; then
  read -e -p "Target directory (default .): " TARGET_DIR_INPUT
  TARGET_DIR="${TARGET_DIR_INPUT:-.}"
fi

# Validate
if [[ ! -d "${TARGET_DIR}" ]]; then
  echo "Error: target directory '${TARGET_DIR}' does not exist." >&2
  exit 1
fi

# Ask for prefix and extension (interactive)
read -e -p "Prefix (example: hstam_115--11_nr_418_ ) : " PREFIX
# Strip possible surrounding quotes/spaces
PREFIX="${PREFIX# }"
PREFIX="${PREFIX% }"
if [[ -z "${PREFIX}" ]]; then
  echo "Error: prefix must not be empty." >&2
  exit 1
fi

read -e -p "Extension without dot (example: tif) : " EXT
EXT="${EXT# }"
EXT="${EXT% }"
if [[ -z "${EXT}" ]]; then
  echo "Error: extension must not be empty." >&2
  exit 1
fi

# Prepare temporary artifacts
TMP_LIST=$(mktemp)
SORTED_LIST=$(mktemp)
TMP_DIR=""
cleanup() {
  # Remove temp files/dir if they still exist
  rm -f "$TMP_LIST" "$SORTED_LIST" 2>/dev/null || true
  # If temp dir exists and is empty, remove it
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    # only remove if empty to avoid accidental removal of user data
    if [[ -z "$(ls -A "$TMP_DIR")" ]]; then
      rmdir "$TMP_DIR" 2>/dev/null || true
    else
      # If there are files left (shouldn't happen in normal flow), leave it and inform
      if (( VERBOSE )); then
        echo "[INFO] Temporary directory left at: $TMP_DIR (not empty)"
      fi
    fi
  fi
}
trap cleanup EXIT

# Discover candidate files (maxdepth 1)
if (( VERBOSE )); then
  echo "[INFO] Scanning for files in '${TARGET_DIR}' matching pattern: ${PREFIX}*.${EXT}"
fi

# Use find to pick files in target dir only
# Use -print0 to safely handle spaces; we will process entries in Bash.
while IFS= read -r -d '' f; do
  base=$(basename "$f")
  # quick sanity: must start with prefix and end with .ext
  if [[ "$base" == "${PREFIX}"*".${EXT}" ]]; then
    # extract numeric suffix candidate
    num="${base#${PREFIX}}"
    num="${num%.$EXT}"
    if [[ "$num" =~ ^[0-9]+$ ]]; then
      printf "%s\t%s\n" "$num" "$f" >> "$TMP_LIST"
      # track max width
      len=${#num}
      # store width in a variable by post-scan
    fi
  fi
done < <(find "$TARGET_DIR" -maxdepth 1 -type f -name "${PREFIX}*.${EXT}" -print0)

if [[ ! -s "$TMP_LIST" ]]; then
  echo "No files found matching pattern ${PREFIX}* .${EXT} with numeric suffixes in ${TARGET_DIR}." >&2
  exit 1
fi

# Compute max padding and sort numerically
PAD=0
while IFS=$'\t' read -r num path; do
  if (( ${#num} > PAD )); then PAD=${#num}; fi
done < "$TMP_LIST"

# sort numerically on the numeric column
sort -n -t $'\t' -k1,1 "$TMP_LIST" > "$SORTED_LIST"

TOTAL=$(wc -l < "$SORTED_LIST" | tr -d ' ')
# ensure padding is at least wide enough to contain TOTAL
if (( ${#TOTAL} > PAD )); then PAD=${#TOTAL}; fi

if (( VERBOSE )); then
  echo "[INFO] Found $TOTAL files; using zero-padding width = $PAD"
fi

# Create a temporary directory inside target dir to avoid cross-filesystem moves
TMP_DIR=$(mktemp -d "${TARGET_DIR}/.rename_tmp.XXXXXX")
if [[ ! -d "$TMP_DIR" ]]; then
  echo "Failed to create temporary directory inside ${TARGET_DIR}" >&2
  exit 1
fi
if (( VERBOSE )); then
  echo "[INFO] Temporary working directory: $TMP_DIR"
fi

# Phase 1: Move originals into temp dir and rename them there to final names
index=1
while IFS=$'\t' read -r num filepath; do
  # compute reversed index: TOTAL-index+1
  rev=$(( TOTAL - index + 1 ))
  newnum=$(printf "%0${PAD}d" "$rev")
  newname="${PREFIX}${newnum}.${EXT}"
  dest="$TMP_DIR/$newname"

  if (( DRY_RUN )); then
    echo "[DRY RUN] Would move: '$filepath' -> '$dest'"
  else
    if (( VERBOSE )); then
      echo "[MOVE] '$filepath' -> '$dest'"
    fi
    # Perform move into tempdir (rename to final name in tempdir)
    mv -- "$filepath" "$dest"
  fi

  index=$(( index + 1 ))
done < "$SORTED_LIST"

# Phase 2: Move files back from temp dir to target dir
# But check collisions first (only when not dry-run)
if (( ! DRY_RUN )); then
  for f in "$TMP_DIR"/*."$EXT"; do
    # if no files, break
    [[ -e "$f" ]] || continue
    base=$(basename "$f")
    dest="$TARGET_DIR/$base"
    if [[ -e "$dest" ]]; then
      echo "Error: destination already exists: $dest. Aborting to avoid overwrite." >&2
      exit 1
    fi
  done
fi

# Now actually move back (or print if dry-run)
for f in "$TMP_DIR"/*."$EXT"; do
  [[ -e "$f" ]] || continue
  base=$(basename "$f")
  dest="$TARGET_DIR/$base"
  if (( DRY_RUN )); then
    echo "[DRY RUN] Would move back: '$f' -> '$dest'"
  else
    if (( VERBOSE )); then
      echo "[MOVE BACK] '$f' -> '$dest'"
    fi
    mv -- "$f" "$dest"
  fi
done

# Remove temporary directory (if empty). cleanup via trap will try as well.
if (( DRY_RUN )); then
  echo "[DRY RUN] Completed simulation. No files were changed."
  # remove tmp dir we created (it should be empty)
  rm -rf "$TMP_DIR" 2>/dev/null || true
else
  # try remove tmp dir; if not empty, keep (trap already handles info)
  rmdir "$TMP_DIR" 2>/dev/null || true
  echo "[OK] Renaming completed. Temporary directory removed (if empty)."
fi
