#!/usr/bin/env bash
# restore_md5_verbose.sh
# Purpose: rename files in a directory based on MD5 mapping from an old.md5 file.
# Messages and comments are in English.
# Usage example:
#   ./restore_md5_verbose.sh -o old.md5 -d hstam/4_b/581 --dry-run --verbose
#
set -u   # do not enable -e; we want to continue on per-file errors

print_usage() {
  cat <<EOF
Usage: $0 -o OLD_MD5 -d DIR [options]

Options:
  -o, --old FILE        old.md5 file (contains md5 and the original path)
  -d, --dir DIR         directory that currently has the wrongly named files
  -r, --recursive       search recursively (default: top-level only)
      --dry-run         do not actually rename files, only show actions
      --overwrite       overwrite target files if they exist
      --verbose         print detailed messages for every processed file
  -h, --help            show this help
EOF
}

OLD_MD5=""
DIR=""
RECURSIVE=0
DRY_RUN=0
OVERWRITE=0
VERBOSE=0

# parse args (simple)
ARGS=$(getopt -o o:d:rh --long old:,dir:,recursive,dry-run,overwrite,verbose,help -n "$0" -- "$@") || { print_usage; exit 1; }
eval set -- "$ARGS"
while true; do
  case "$1" in
    -o|--old) OLD_MD5="$2"; shift 2;;
    -d|--dir) DIR="$2"; shift 2;;
    -r|--recursive) RECURSIVE=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --overwrite) OVERWRITE=1; shift;;
    --verbose) VERBOSE=1; shift;;
    -h|--help) print_usage; exit 0; shift;;
    --) shift; break;;
    *) break;;
  esac
done

if [[ -z "$OLD_MD5" || -z "$DIR" ]]; then
  echo "Error: --old and --dir are required." >&2
  print_usage
  exit 2
fi

if [[ ! -f "$OLD_MD5" ]]; then
  echo "Error: old md5 file not found: $OLD_MD5" >&2
  exit 3
fi

if [[ ! -d "$DIR" ]]; then
  echo "Error: directory not found: $DIR" >&2
  exit 4
fi

echo "Loading mappings from: $OLD_MD5"
declare -A MAP_TARGET
declare -A MAP_DUP
# Read old.md5 and build md5 -> basename mapping (first mapping wins)
while IFS= read -r line || [[ -n "$line" ]]; do
  md5=$(printf '%s' "$line" | grep -Eo '[a-fA-F0-9]{32}' | head -n1 || true)
  if [[ -z "$md5" ]]; then
    continue
  fi
  rest=$(printf '%s' "$line" | sed -n "s/.*${md5}[[:space:]]*//p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [[ -z "$rest" ]]; then
    rest=$(printf '%s' "$line" | awk '{print $NF}')
  fi
  tgt_basename=$(basename -- "$rest")
  if [[ -z "${MAP_TARGET[$md5]:-}" ]]; then
    MAP_TARGET[$md5]="$tgt_basename"
  else
    MAP_DUP[$md5]="${MAP_DUP[$md5]:-}${MAP_TARGET[$md5]}|${tgt_basename}"
  fi
done < "$OLD_MD5"

echo "Total mappings read: ${#MAP_TARGET[@]}"

# Build find command
if [[ $RECURSIVE -eq 1 ]]; then
  FIND_CMD=(find "$DIR" -type f -print0)
else
  FIND_CMD=(find "$DIR" -maxdepth 1 -type f -print0)
fi

# Counters
i=0
renamed=0
no_match=0
conflict=0
md5fail=0
mvfail=0

# Iterate files robustly (null-delimited)
while IFS= read -r -d '' file; do
  ((i++))
  printf '[%04d] ' "$i"
  # compute md5
  md5=$(md5sum -- "$file" 2>/dev/null | awk '{print $1}') || md5=""
  if [[ -z "$md5" ]]; then
    echo "MD5_FAIL: $file"
    ((md5fail++))
    continue
  fi

  target="${MAP_TARGET[$md5]:-}"
  if [[ -z "$target" ]]; then
    echo "NO_MATCH md5=$md5 file=$file"
    ((no_match++))
    continue
  fi

  curbase=$(basename -- "$file")
  if [[ "$curbase" == "$target" ]]; then
    echo "ALREADY_OK md5=$md5 file=$file"
    continue
  fi

  dstdir=$(dirname -- "$file")
  dst="$dstdir/$target"
  if [[ -e "$dst" && $OVERWRITE -ne 1 ]]; then
    echo "CONFLICT target exists: $dst  (source: $file)"
    ((conflict++))
    continue
  fi

  echo "RENAME: $file -> $dst (md5=$md5)"
  if [[ $DRY_RUN -eq 0 ]]; then
    if mv -f -- "$file" "$dst"; then
      ((renamed++))
    else
      echo "MOVE_FAILED: $file -> $dst" >&2
      ((mvfail++))
    fi
  else
    ((renamed++))  # count as would-be-renamed
  fi

done < <("${FIND_CMD[@]}")

# Summary
echo "---- SUMMARY ----"
echo "Files scanned: $i"
echo "Renamed (or dry-run count): $renamed"
echo "No match: $no_match"
echo "Conflicts: $conflict"
echo "MD5 failures: $md5fail"
echo "Move failures: $mvfail"

if [[ ${#MAP_DUP[@]} -gt 0 ]]; then
  echo
  echo "Warning: duplicate mappings in old.md5 (first mapping used):"
  for k in "${!MAP_DUP[@]}"; do
    echo "  $k -> ${MAP_DUP[$k]}"
  done
fi

exit 0