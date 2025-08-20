#!/usr/bin/env bash
###############################################################################
# Script Name : md5_update_paths.sh
# Version     : 3.1
# Author      : Mustafa Demiroglu
# Purpose     : Update file paths or filenames in MD5 checksum files without moving files.
#               - Mode 1: Standard path update with optional rename rule
#                         CSV (3 cols): Source_Pfad,Ziel_Pfad,New_filenames
#                         - If third col equals 'rename' (case-insensitive):
#                           new filename base is built from Ziel_Pfad as:
#                           "<first>_<second>_nr_<last>_<INDEX>.ext"
#                           (INDEX: preserved from original filename, e.g. 0007)
#               - Mode 2: Simple rename (two-column CSV: old_name,new_name)
#                         Exact match on the path part in MD5 lines.
#               - Mode 3: Process ALL .md5 files in directory (Modes 1 or 2)
#               - Mode 4: Clean old backups and logs
#
# Notes:
#   * MD5 file lines are expected as: "<hash><space><path/filename>"
#   * Paths are updated only in the <path/filename> portion; hash stays intact.
#   * No files are moved/renamed on disk — only MD5 entries are updated.
#
# Tested Shells: bash 4+ (Linux, Git Bash on Windows)
###############################################################################

set -euo pipefail

# Colors
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
BLUE="\033[0;34m"
NC="\033[0m"

# Globals
SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date +"%Y%m%d_%H%M%S")"
LOG_FILE="md5_update_paths_output_${TIMESTAMP}.log"

# Utilities -------------------------------------------------------------------

die() {
  echo -e "${RED}ERROR:${NC} $*" >&2
  exit 1
}

info() {
  echo -e "${CYAN}INFO:${NC} $*"
}

warn() {
  echo -e "${YELLOW}WARNING:${NC} $*"
}

success() {
  echo -e "${GREEN}SUCCESS:${NC} $*"
}

trim() {
  # usage: trim "  text  "
  local s="$1"
  # shellcheck disable=SC2001
  s="$(echo "$s" | sed -e 's/^[[:space:]]\+//' -e 's/[[:space:]]\+$//')"
  printf "%s" "$s"
}

to_lower() {
  printf "%s" "$1" | tr '[:upper:]' '[:lower:]'
}

is_header_like() {
  # heuristic: if the first field contains alphabetic characters and not a path with slash+digits
  # or matches known headers
  local f1="$(to_lower "$(trim "$1")")"
  case "$f1" in
    source_pfad|ziel_pfad|new_filenames|old_name|new_name|old_filename|new_filename|old_filenames|new_filenames)
      return 0 ;;
  esac
  return 1
}

# Parse MD5 line into HASH + PATH ---------------------------------------------
parse_md5_line() {
  # Reads one MD5 line on stdin, prints "HASH<TAB>PATH"
  # Handles one space or multiple spaces between hash and path.
  awk '{
    if (NF < 2) next;
    hash=$1;
    $1="";
    sub(/^ +/,"");
    path=$0;
    print hash "\t" path;
  }'
}

# Build new base name from Ziel_Pfad: "<first>_<second>_nr_<last>"
build_base_from_dest() {
  local dest="$1"
  # remove leading "./" if present
  dest="${dest#./}"
  # normalize consecutive slashes
  dest="$(echo "$dest" | sed -E 's#/+#/#g')"
  IFS='/' read -r -a seg <<< "$dest"
  local n="${#seg[@]}"
  if (( n == 0 )); then
    printf "" ; return
  fi
  local first="${seg[0]}"
  local second=""
  local last="${seg[$((n-1))]}"
  if (( n >= 2 )); then
    second="${seg[1]}"
  fi
  if [[ -z "$second" ]]; then
    printf "%s_nr_%s" "$first" "$last"
  else
    printf "%s_%s_nr_%s" "$first" "$second" "$last"
  fi
}

# Extract 4-digit index from filename end: *_NNNN.ext -> NNNN
extract_index4() {
  local fname="$1"
  local idx=""
  if [[ "$fname" =~ (_[0-9]{4})(\.[^.]+)$ ]]; then
    idx="${BASH_REMATCH[1]}"   # includes leading underscore
  fi
  printf "%s" "$idx"
}

# Replace path prefix ----------------------------------------------------------
replace_prefix() {
  # replace_prefix "<fullpath>" "<src_prefix>" "<dst_prefix>"
  local full="$1" src="$2" dst="$3"
  # Normalize
  full="$(echo "$full" | sed -E 's#/+#/#g')"
  src="$(echo "$src" | sed -E 's#/+#/#g')"
  dst="$(echo "$dst" | sed -E 's#/+#/#g')"
  if [[ "$full" == "$src" ]]; then
    printf "%s" "$dst"
  elif [[ "$full" == "$src/"* ]]; then
    printf "%s/%s" "$dst" "${full#$src/}"
  else
    # no change
    printf "%s" "$full"
  fi
}

# Safe write to temp + move ----------------------------------------------------
write_lines_to_file() {
  local dest="$1"
  local tmp="${dest}.tmp.${TIMESTAMP}"
  cat > "$tmp"
  mv -f -- "$tmp" "$dest"
}

# Back up file -----------------------------------------------------------------
make_backup() {
  local f="$1"
  local b="${f}.backup.${TIMESTAMP}"
  cp -f -- "$f" "$b"
  success "Backup created: $b"
}

# CSV reading helpers ----------------------------------------------------------
read_csv_2cols() {
  # Reads 2-col CSV from stdin; prints "A<TAB>B"; skips header-like first line
  awk -F',' 'NR==1 && ($1 ~ /old[_ ]?name|old[_ ]?filename/i) {next}
             {print $1 "\t" $2}'
}

read_csv_3cols() {
  # Reads 3-col CSV from stdin; prints "A<TAB>B<TAB>C"; skips header-like first line
  awk -F',' 'NR==1 && ($1 ~ /source[_ ]?pfad/i) {next}
             {print $1 "\t" $2 "\t" $3}'
}

# Mode 1: Standard path update with optional rename ---------------------------
update_md5_with_path_changes() {
  local md5_file="$1"
  local csv_file="$2"

  [[ -f "$md5_file" ]] || die "MD5 file not found: $md5_file"
  [[ -f "$csv_file" ]] || die "CSV file not found: $csv_file"

  info "Loading MD5 file: $md5_file"
  mapfile -t md5_lines < "$md5_file"
  local total="${#md5_lines[@]}"
  info "MD5 entries: $total"

  info "Reading CSV instructions (Source_Pfad,Ziel_Pfad,New_filenames)"
  mapfile -t rules < <(read_csv_3cols < "$csv_file")
  local rules_count="${#rules[@]}"
  info "Rules: $rules_count"

  if (( rules_count == 0 )); then
    warn "No CSV rows found (after header filtering). Nothing to do."
    return 0
  fi

  make_backup "$md5_file"

  local updates=0

  # Build an array of output lines
  declare -a out_lines
  out_lines=()

  for line in "${md5_lines[@]}"; do
    # Parse MD5 line -> HASH \t PATH
    if ! parsed="$(echo "$line" | parse_md5_line)"; then
      # keep as-is if unparsable
      out_lines+=("$line")
      continue
    fi
    local hash path new_path applied
    hash="${parsed%%$'\t'*}"
    path="${parsed#*$'\t'}"
    applied=0
    new_path="$path"

    for rule in "${rules[@]}"; do
      IFS=$'\t' read -r src dst flag <<< "$rule"
      src="$(trim "$src")"
      dst="$(trim "$dst")"
      flag="$(to_lower "$(trim "${flag:-}")")"

      [[ -z "$src" || -z "$dst" ]] && continue

      # If path starts with src prefix -> replace with dst (keeping the suffix)
      if [[ "$new_path" == "$src" || "$new_path" == "$src/"* ]]; then
        local replaced
        replaced="$(replace_prefix "$new_path" "$src" "$dst")"

        if [[ "$flag" == "rename" ]]; then
          # We must also rename the FILENAME using the preserved index
          local fname="${replaced##*/}"
          local dir="${replaced%/*}"
          local ext=""
          [[ "$fname" =~ (\.[^.]+)$ ]] && ext="${BASH_REMATCH[1]}"

          # INDEX as suffix like _0007
          local idx="$(extract_index4 "$replaced")"
          if [[ -z "$idx" ]]; then
            # Try to get index from original filename (before replace)
            local old_idx="$(extract_index4 "$new_path")"
            [[ -n "$old_idx" ]] && idx="$old_idx"
          fi

          # Build new base name from destination path
          local base="$(build_base_from_dest "$dst")"
          if [[ -z "$ext" ]]; then
            # derive from original
            if [[ "$fname" =~ (\.[^.]+)$ ]]; then ext="${BASH_REMATCH[1]}"; else ext=".tif"; fi
          fi
          # If no index found, keep original filename (safety)
          if [[ -z "$idx" ]]; then
            warn "No 4-digit index found in '$replaced'; keeping original filename."
            replaced="$dir/$fname"
          else
            replaced="$dir/${base}${idx}${ext}"
          fi
        fi

        new_path="$replaced"
        applied=1
        # Important: apply only first matching rule per line
        break
      fi
    done

    if (( applied )); then
      ((updates++))
    fi
    out_lines+=("$hash  $new_path")
  done

  # Write back
  printf "%s\n" "${out_lines[@]}" | write_lines_to_file "$md5_file"
  success "Updated lines: $updates"
}

# Mode 2: Simple rename (two-column CSV) --------------------------------------
simple_rename_md5() {
  local md5_file="$1"
  local csv_file="$2"

  [[ -f "$md5_file" ]] || die "MD5 file not found: $md5_file"
  [[ -f "$csv_file" ]] || die "CSV file not found: $csv_file"

  info "Loading MD5 file: $md5_file"
  mapfile -t md5_lines < "$md5_file"
  local total="${#md5_lines[@]}"
  info "MD5 entries: $total"

  info "Reading CSV (old_name,new_name)"
  mapfile -t pairs < <(read_csv_2cols < "$csv_file")
  local n_pairs="${#pairs[@]}"
  info "Rename instructions: $n_pairs"

  if (( n_pairs == 0 )); then
    warn "No CSV rows found (after header filtering). Nothing to do."
    return 0
  fi

  make_backup "$md5_file"

  local updates=0
  declare -A map_old2new
  local p old new

  for p in "${pairs[@]}"; do
    IFS=$'\t' read -r old new <<< "$p"
    old="$(trim "$old")"
    new="$(trim "$new")"
    [[ -z "$old" || -z "$new" ]] && continue
    map_old2new["$old"]="$new"
  done

  declare -a out_lines
  out_lines=()

  local line hash path new_path
  for line in "${md5_lines[@]}"; do
    if ! parsed="$(echo "$line" | parse_md5_line)"; then
      out_lines+=("$line")
      continue
    fi
    hash="${parsed%%$'\t'*}"
    path="${parsed#*$'\t'}"

    if [[ -n "${map_old2new[$path]+x}" ]]; then
      new_path="${map_old2new[$path]}"
      ((updates++))
    else
      new_path="$path"
    fi
    out_lines+=("$hash  $new_path")
  done

  printf "%s\n" "${out_lines[@]}" | write_lines_to_file "$md5_file"
  success "Updated lines: $updates"
}

# Mode 3: Process ALL .md5 files in directory ---------------------------------
process_all_md5_in_dir() {
  local mode="$1"  # "1" or "2"
  local csv_file="$2"
  local base_dir="$3"

  shopt -s nullglob
  local files=("$base_dir"/*.md5)
  shopt -u nullglob

  if (( ${#files[@]} == 0 )); then
    warn "No .md5 files found in: $base_dir"
    return 0
  fi

  info "Processing ${#files[@]} MD5 files in '$base_dir' (mode $mode)"
  local f
  for f in "${files[@]}"; do
    if [[ "$mode" == "1" ]]; then
      update_md5_with_path_changes "$f" "$csv_file"
    else
      simple_rename_md5 "$f" "$csv_file"
    fi
  done
}

# Mode 4: Clean backups and logs ----------------------------------------------
clean_backups_and_logs() {
  local base_dir="$1"
  info "Cleaning backup and log files in: $base_dir"
  find "$base_dir" -maxdepth 1 -type f \( -name "*.backup.*" -o -name "md5_update_paths_output_*.log" \) -print -delete
  success "Cleanup done."
}

# Interactive helpers ----------------------------------------------------------
select_from_list() {
  # Prints menu and reads selection number
  local prompt="$1"; shift
  local -a items=("$@")
  local i
  echo -e "${BLUE}$prompt${NC}"
  for ((i=0;i<${#items[@]};i++)); do
    echo "  $((i+1))) ${items[$i]}"
  done
  local choice
  read -rp "Enter your choice (1-${#items[@]}): " choice
  [[ "$choice" =~ ^[1-9][0-9]*$ ]] || die "Invalid selection."
  (( choice >=1 && choice <= ${#items[@]} )) || die "Out of range."
  echo "$choice"
}

pick_file_with_pattern() {
  local pattern="$1"
  local -a files=()
  while IFS= read -r -d '' f; do files+=("$f"); done < <(find . -maxdepth 1 -type f -name "$pattern" -print0 | sort -z)
  (( ${#files[@]} > 0 )) || die "No files matching pattern: $pattern"
  local choice
  choice="$(select_from_list "Available files:" "${files[@]}")"
  echo "${files[$((choice-1))]}"
}

# Main Menu -------------------------------------------------------------------
main_menu() {
  echo -e "${GREEN}=== MD5 Checksum Path Update Script v2.1 ===${NC}"
  echo "This tool updates file paths in MD5 checksum files without moving actual files."
  echo
  local base_dir=""
  read -rp "Base directory (leave empty for current): " base_dir
  if [[ -z "$base_dir" ]]; then
    base_dir="$PWD"
  fi
  cd "$base_dir" || die "Cannot enter directory: $base_dir"
  info "Working directory: $PWD"

  echo
  echo -e "${BLUE}=== Main Menu ===${NC}"
  echo "  1) Update MD5 file with path changes (Source_Pfad -> Ziel_Pfad)"
  echo "  2) Update MD5 file with simple renames (old_name -> new_name)"
  echo "  3) Process ALL .md5 files in directory (choose 1 or 2)"
  echo "  4) Clean old backup and log files"
  echo "  5) Exit"
  read -rp "Enter choice (1-5): " choice

  case "$choice" in
    1)
      local csv md5
      csv="$(pick_file_with_pattern "*.csv")"
      md5="$(pick_file_with_pattern "*.md5")"
      info "CSV: $csv"
      info "MD5: $md5"
      update_md5_with_path_changes "$md5" "$csv"
      ;;
    2)
      local csv md5
      csv="$(pick_file_with_pattern "*.csv")"
      md5="$(pick_file_with_pattern "*.md5")"
      info "CSV: $csv"
      info "MD5: $md5"
      simple_rename_md5 "$md5" "$csv"
      ;;
    3)
      local submode csv
      echo "Choose submode:"
      echo "  1) Path changes (3-col CSV)"
      echo "  2) Simple rename (2-col CSV)"
      read -rp "Enter (1-2): " submode
      csv="$(pick_file_with_pattern "*.csv")"
      process_all_md5_in_dir "$submode" "$csv" "$PWD"
      ;;
    4)
      clean_backups_and_logs "$PWD"
      ;;
    5) ;;
    *)
      die "Invalid choice."
      ;;
  esac

  echo -e "${GREEN}=== Script Execution Completed Successfully! ===${NC}"
}

# If called without args -> interactive menu
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main_menu
fi
