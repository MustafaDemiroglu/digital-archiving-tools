#!/usr/bin/env bash
set -euo pipefail

# Purpose:
#   Rename files in a directory to their original names based on a correct old.md5 file.
#   The script computes MD5 for files currently in the directory and matches them to MD5s
#   listed in old.md5. When a match is found the file is renamed to the basename from old.md5.
# Notes:
#   - This script uses null-delimited I/O (find -print0 + read -d '') to safely handle special chars.
#   - All user-facing messages and comments are in English as requested.
#   - Use --dry-run to preview actions.
#
# Usage:
#   ./simple_restore_by_md5_fixed.sh -o old.md5 -d /path/to/dir [--recursive] [--dry-run] [--overwrite]
#

usage() {
  cat <<EOF
Usage: $0 -o OLD_MD5 -d DIR [options]

Options:
  -o, --old FILE        old md5 file (format: "<md5> <path>" per line)
  -d, --dir DIR         directory containing the files to be renamed
  -r, --recursive       search files recursively (default: only top-level files in DIR)
      --dry-run         don't perform moves, only print what would be done
      --overwrite       overwrite target file if it already exists
  -h, --help            show this help
EOF
  exit 1
}

# defaults
OLD=""
DIR=""
RECURSIVE=0
DRY_RUN=0
OVERWRITE=0

# parse args
ARGS=$(getopt -o o:d:rh --long old:,dir:,recursive,dry-run,overwrite,help -n "$0" -- "$@") || usage
eval set -- "$ARGS"
while true; do
  case "$1" in
    -o|--old) OLD="$2"; shift 2;;
    -d|--dir) DIR="$2"; shift 2;;
    -r|--recursive) RECURSIVE=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --overwrite) OVERWRITE=1; shift;;
    -h|--help) usage; shift;;
    --) shift; break;;
    *) break;;
  esac
done

if [[ -z "$OLD" || -z "$DIR" ]]; then
  echo "Error: -o (old.md5) and -d (directory) are required." >&2
  usage
fi

if [[ ! -f "$OLD" ]]; then
  echo "Error: old.md5 not found: $OLD" >&2
  exit 2
fi

if [[ ! -d "$DIR" ]]; then
  echo "Error: directory not found: $DIR" >&2
  exit 3
fi

# Read old.md5 and build map md5 -> target_basename
declare -A target_by_md5
declare -A duplicate_md5
while IFS= read -r line || [ -n "$line" ]; do
  # extract first 32-hex MD5 on the line
  md5=$(printf '%s' "$line" | grep -Eo '[a-fA-F0-9]{32}' | head -n1 || true)
  if [[ -z "$md5" ]]; then
    continue
  fi
  # extract the path token after the md5; fallback to last token if greedy extraction fails
  rest=$(printf '%s' "$line" | sed -n "s/.*${md5}[[:space:]]*//p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [[ -z "$rest" ]]; then
    rest=$(printf '%s' "$line" | awk '{print $NF}')
  fi
  tgt_basename=$(basename "$rest")
  if [[ -z "${target_by_md5[$md5]:-}" ]]; then
    target_by_md5[$md5]="$tgt_basename"
  else
    # record duplicates but keep first mapping
    duplicate_md5[$md5]="${duplicate_md5[$md5]:-}${target_by_md5[$md5]}|${tgt_basename}"
  fi
done < "$OLD"

if [[ ${#target_by_md5[@]} -eq 0 ]]; then
  echo "Warning: no MD5 entries parsed from $OLD" >&2
  exit 4
fi

# Prepare find command
if [[ $RECURSIVE -eq 1 ]]; then
  FIND_CMD=(find "$DIR" -type f -print0)
else
  FIND_CMD=(find "$DIR" -maxdepth 1 -type f -print0)
fi

# Counters
renamed=0
no_match=0
conflicts=0
skipped=0

# Process files using null-delimited read to be robust with special characters
while IFS= read -r -d '' f; do
  # compute md5
  if ! md5=$(md5sum -- "$f" 2>/dev/null | awk '{print $1}'); then
    echo "Warning: unable to compute md5 for: $f" >&2
    ((skipped++))
    continue
  fi

  tgt_basename="${target_by_md5[$md5]:-}"
  if [[ -z "$tgt_basename" ]]; then
    echo "No md5 mapping for: $f (md5=$md5)"
    ((no_match++))
    continue
  fi

  cur_basename=$(basename -- "$f")
  if [[ "$cur_basename" == "$tgt_basename" ]]; then
    echo "Already correct name: $cur_basename"
    continue
  fi

  dst_dir=$(dirname -- "$f")
  dst="$dst_dir/$tgt_basename"

  if [[ -e "$dst" && $OVERWRITE -ne 1 ]]; then
    echo "Conflict: target exists and --overwrite not set: $dst  (source: $f)"
    ((conflicts++))
    continue
  fi

  echo "Rename: '$f' -> '$dst'"
  if [[ $DRY_RUN -eq 0 ]]; then
    # perform move (force if overwrite)
    if [[ $OVERWRITE -eq 1 ]]; then
      mv -f -- "$f" "$dst"
    else
      mv -- "$f" "$dst"
    fi
  fi
  ((renamed++))

done < <("${FIND_CMD[@]}")

# Summary
echo
echo "Summary:"
echo "  Files found in dir: (see find output above)"
echo "  Renamed:      $renamed"
echo "  No md5 match: $no_match"
echo "  Conflicts:    $conflicts"
echo "  Skipped:      $skipped"

if [[ ${#duplicate_md5[@]} -gt 0 ]]; then
  echo
  echo "Note: duplicate md5 entries were found in old.md5 (first mapping was used):"
  for k in "${!duplicate_md5[@]}"; do
    echo "  $k -> ${duplicate_md5[$k]}"
  done
fi

exit 0