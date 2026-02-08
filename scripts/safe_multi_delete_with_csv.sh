#!/usr/bin/env bash
###############################################################################
# Script Name: safe_multi_delete_with_csv.sh
# Version: 7.1.1
# Author: Mustafa Demiroglu
# Organisation: HlaDigiTeam
#
# Description:
#   Safely delete files listed in a CSV/TXT/LIST file.
#   Works on Linux, macOS, and WSL. Compatible with common bash versions.
#
# Features:
#   - Auto-detects column separator: TAB, ; , , | or space.
#   - Accepts relative, absolute, and Windows-style paths.
#   - Path normalization:
#       * Converts Windows paths (C:\foo\bar) to /mnt/c/foo/bar on Linux/WSL.
#       * Removes duplicate slashes and "./".
#       * If an absolute like "/hstad/..." does not exist, also tries
#         "$PWD/hstad/..." (treat as project-relative).
#   - Dry-run mode (-n): prints planned actions. No deletions.
#   - Parallel mode (-p): deletes using multiple CPU cores.
#   - Always writes logs:
#       * delete_log_YYYYMMDD_HHMMSS.txt
#       * delete_errors_YYYYMMDD_HHMMSS.txt
#       * dirs_not_found_to_delete_YYYYMMDD_HHMMSS.list
#   - Interactive preview & confirmation in real mode (even without -v).
#
# CSV format note:
#   - If a second column exists, ONLY rows with value "delete" will be processed.
#   - If there is no second column (plain list), all rows will be treated as delete.
#
# Usage:
#   ./safe_multi_delete_with_csv.sh -f list.csv -n
#   ./safe_multi_delete_with_csv.sh --file files.txt -p -v
#
# Don't forget:
#   - to use header, if u dont't have an header just write an empty first line or anything to first line
# 
# Options:
#   -f, --file <path>  : CSV/TXT/List file to process
#   -n, --dry-run      : Dry run mode (no deletions, only prints actions)
#   -p, --parallel     : Run deletions in parallel
#   -v, --verbose      : Verbose output
#   -h, --help         : Show this help
###############################################################################

set -euo pipefail

# Defaults
DRYRUN=false
VERBOSE=false
PARALLEL=false
FILE=""
SEP=$'\t'   # will be auto-detected
NOWSTAMP="$(date +%Y%m%d_%H%M%S)"
LOGFILE="delete_log_${NOWSTAMP}.txt"
ERRFILE="delete_errors_${NOWSTAMP}.txt"
NOTFOUND_FILE="dirs_not_found_to_delete_${NOWSTAMP}.list"


# --------------------------- Helpers & Logging -------------------------------

print_help() { sed -n '2,70p' "$0"; }

log() {  # always echo + append to log
  echo "$*" | tee -a "$LOGFILE"
}

log_only() {  # append to log silently; echo only if verbose
  if $VERBOSE; then
    echo "[INFO] $*" | tee -a "$LOGFILE"
  else
    echo "$*" >>"$LOGFILE"
  fi
}

trim() {
  # trim leading/trailing whitespace + strip CR
  local s="$1"
  s="${s%$'\r'}"
  # leading
  s="${s#"${s%%[![:space:]]*}"}"
  # trailing
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

get_cpu_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu 2>/dev/null || echo 4
  elif command -v getconf >/dev/null 2>&1; then
    getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4
  else
    echo 4
  fi
}

# ------------------------------ Path handling --------------------------------

windows_to_unix_path() {
  # Convert "C:\path\to\file" or "C:/path/to/file" -> "/mnt/c/path/to/file"
  local p="$1"
  if [[ "$p" =~ ^[A-Za-z]:[\\/].* ]]; then
    local drive="${p:0:1}"
    p="/mnt/$(lower "$drive")/${p:2}"
    p="${p//\\//}"
  fi
  printf '%s' "$p"
}

normalize_path() {
  # Make path resolvable; try multiple fallbacks relative to CWD.
  local raw="$1"
  local p
  p="$(windows_to_unix_path "$raw")"
  p="${p//\\//}"        # backslashes -> slashes
  p="${p#./}"           # strip leading ./
  p="${p//\/\//\/}"     # collapse //
  # Expand ~
  if [[ "$p" == "~"* ]]; then
    p="${p/#\~/$HOME}"
  fi

  # If relative -> absolute under PWD
  if [[ "$p" != /* ]]; then
    p="$(pwd)/$p"
  fi
  p="${p//\/\//\/}"

  # If absolute but missing, and starts like /name/... (e.g., /hstad/..),
  # also try "$PWD/name/..." as project-relative.
  if [[ ! -e "$p" && "$p" == /*/* ]]; then
    local nolead="${p#/}"         # drop first '/'
    local alt="$(pwd)/$nolead"    # try relative to CWD
    alt="${alt//\/\//\/}"
    if [[ -e "$alt" ]]; then
      p="$alt"
    fi
  fi

  printf '%s' "$p"
}

# ------------------------------ CSV handling ---------------------------------

choose_file_if_missing() {
  if [[ -z "$FILE" ]]; then
    echo "No CSV/TXT/List file provided."
    echo "Searching for candidate files in current directory..."
    local choices=( *.csv *.CSV *.txt *.TXT *.list *.LIST )
    local filtered=()
    for f in "${choices[@]}"; do [[ -f "$f" ]] && filtered+=("$f"); done
    if [[ "${#filtered[@]}" -eq 0 ]]; then
      echo "No candidate file found. Exiting."
      exit 1
    fi
    echo "Select file to process:"
    select f in "${filtered[@]}"; do FILE="$f"; break; done
  fi
}

detect_separator() {
  local header
  header="$(head -n1 "$FILE" | tr -d '\r')"
  # Priority: TAB > ; > , > | > space
  if [[ "$header" == *$'\t'* ]]; then
    SEP=$'\t'
  elif [[ "$header" == *";"* ]]; then
    SEP=";"
  elif [[ "$header" == *","* ]]; then
    SEP=","
  elif [[ "$header" == *"|"* ]]; then
    SEP="|"
  elif [[ "$header" == *" "* ]]; then
    SEP=" "
  else
    SEP=$'\t'
  fi
}

collect_delete_candidates() {
  # Outputs normalized file paths (one per line) whose To-Do == delete
  local is_first=1
  local line f todo
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip header (first line)
    if (( is_first )); then is_first=0; continue; fi
    line="${line%$'\r'}"
    # Split into two columns by detected separator
    IFS="$SEP" read -r f todo _rest <<< "$line"
    f="$(trim "$f")"
    todo="$(trim "$todo")"
    todo="$(lower "$todo")"
    [[ -z "$f" ]] && continue
    # If second column exists, require "delete"
	# If no second column (plain list), delete anyway
	if [[ -z "$todo" || "$todo" == "delete" ]]; then
	  normalize_path "$f"
	  echo
	fi
  done < "$FILE"
}

preview_and_confirm() {
  # Show planned deletions (existing + missing) and ask confirmation.
  local -a all=("$@")
  local -a exist=()
  local -a missing=()
  local x
  for x in "${all[@]}"; do
    if [[ -e "$x" ]]; then
      exist+=("$x")
    else
      missing+=("$x")
    fi
  done

  log "Planned deletions: ${#all[@]} file(s)."
  if ((${#exist[@]})); then
    log "Existing files to delete (${#exist[@]}):"
    printf '  %s\n' "${exist[@]}" | tee -a "$LOGFILE"
  else
    log "Existing files to delete (0)."
  fi
  if ((${#missing[@]})); then
    log "Not found (${#missing[@]}):"
    printf '  %s\n' "${missing[@]}" | tee -a "$LOGFILE"
  fi

  if ((${#exist[@]} == 0)); then
    log "Nothing to delete."
    return 1
  fi

  read -rp "Proceed to DELETE ${#exist[@]} file(s)? [y/N]: " ans
  case "$ans" in
    [yY]|[yY][eE][sS]) return 0 ;;
    *) log "Aborted by user."; return 1 ;;
  esac
}

delete_serial() {
  local -a arr=("$@")
  local f
  for f in "${arr[@]}"; do
    if rm -rf -- "$f"; then
      log "[DELETED] $f"
    else
      echo "[ERROR] Could not delete: $f" | tee -a "$ERRFILE"
    fi
  done
}

delete_parallel() {
  local -a arr=("$@")
  local nproc
  nproc="$(get_cpu_count)"
  # Use NUL delimiters for safety
  printf '%s\0' "${arr[@]}" | xargs -0 -I{} -P "$nproc" bash -c '
    f="$1"
    if rm -rf -- "$f"; then
      echo "[DELETED] $f" >> "'"$LOGFILE"'"
      echo "[DELETED] $f"
    else
      echo "[ERROR] Could not delete: $f" | tee -a "'"$ERRFILE"'"
    fi
  ' _ {}
}

# ------------------------------- Arg parsing ---------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file) FILE="$2"; shift 2 ;;
    -n|--dry-run) DRYRUN=true; shift ;;
    -p|--parallel) PARALLEL=true; shift ;;
    -v|--verbose) VERBOSE=true; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) echo "Unknown option: $1"; print_help; exit 1 ;;
  esac
done

# ---------------------------------- Main -------------------------------------

touch "$LOGFILE" "$ERRFILE"
choose_file_if_missing
detect_separator

log "Using file: $FILE"
log "Log file: $LOGFILE"
log "Error file: $ERRFILE"

# Collect candidates (normalized)
mapfile -t CANDIDATES < <(collect_delete_candidates)

# Collect NOT FOUND paths (single responsibility)
for f in "${CANDIDATES[@]}"; do
  [[ ! -e "$f" ]] && echo "$f" >> "$NOTFOUND_FILE"
done

if [[ -s "$NOTFOUND_FILE" ]]; then
  log "Not found paths written to: $NOTFOUND_FILE"
fi

# ------------------------------ DRY RUN --------------------------------------
if $DRYRUN; then
  log "==== DRY RUN MODE ===="
  log "No files will be deleted. These are the planned actions:"
  if ((${#CANDIDATES[@]})); then
    printf '[DRY-RUN] Would delete: %s\n' "${CANDIDATES[@]}" | tee -a "$LOGFILE"
  else
    log "No matching 'delete' items found."
  fi
  echo "Done. Logs written to $LOGFILE, errors to $ERRFILE."
  exit 0
fi

# Real mode: preview + confirm, then delete
if ! preview_and_confirm "${CANDIDATES[@]}"; then
  echo "Done. Logs written to $LOGFILE, errors to $ERRFILE."
  exit 0
fi

# Filter to existing files only for deletion
EXISTING=()
for f in "${CANDIDATES[@]}"; do
  [[ -e "$f" ]] && EXISTING+=("$f")
done

if ((${#EXISTING[@]} == 0)); then
  log "Nothing to delete after re-check."
  echo "Done. Logs written to $LOGFILE, errors to $ERRFILE."
  exit 0
fi

if $PARALLEL; then
  log_only "Running in parallel mode with $(get_cpu_count) workers"
  delete_parallel "${EXISTING[@]}"
else
  delete_serial "${EXISTING[@]}"
fi

echo "Done. Logs written to $LOGFILE, errors to $ERRFILE."
