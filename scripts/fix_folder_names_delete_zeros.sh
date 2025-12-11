#!/usr/bin/env bash
###############################################################################
# Script Name: fix_folder_names_delete_zeros.sh 
# Version: 2.1 
# Author: Mustafa Demiroglu
# Organisation: HlaDigiTeam
#
# Description:
#   Fixes folder names by removing leading zeros from ANY digit-only segment.
#   Segments may be separated by '--', '..', '_' or even be inside text.
#   Supports dry-run mode (-n or --dry-run).
#   Processes only depth 1 and depth 2 subfolders from BASE_DIR.
#
#   Examples:
#     0014                -> 14
#     0014--007           -> 14--7
#     15_006              -> 15_6
#     frankfurt--18_007   -> frankfurt--18_7
#     0018..004--frankfurt -> 18..4--frankfurt
#     frankfurt0015       -> frankfurt15
#
#   All changes are logged into rename_log.txt
###############################################################################

BASE_DIR="."
DRYRUN=0
LOGFILE="rename_log.txt"

# ------------- ARGUMENT PARSE -----------------
for arg in "$@"; do
    case "$arg" in
        -n|--dry-run)
            DRYRUN=1
            ;;
        *)
            BASE_DIR="$arg"
            ;;
    esac
done
# ----------------------------------------------

echo "==== Folder Rename Started at $(date) ====" >> "$LOGFILE"
echo "BASE_DIR: $BASE_DIR" >> "$LOGFILE"
[[ $DRYRUN -eq 1 ]] && echo "(DRY RUN MODE)" >> "$LOGFILE"

# ----------- Function: fix a name, delete unwanted zeros  -------------
fix_name() {
	# 1) Replace digit-segments like 00015 with cleaned version
    #    Only segments consisting entirely of digits are processed.
    local n="$1"
	local cleaned="$n"

    # Process all pure-digit sequences globally
    while [[ "$cleaned" =~ ([0-9]+) ]]; do
        block="${BASH_REMATCH[1]}"
        trimmed=$(echo "$block" | sed 's/^0*\([0-9]\)/\1/')
        cleaned="${cleaned/$block/$trimmed}"
		
		# safety break → infinite loop protection
        [[ "$cleaned" == "$n" ]] && break
        n="$cleaned"
    done

    echo "$cleaned"
}
# ----------------------------------------------

# Collect directories first Only depth 1 and 2 folders ----------
mapfile -t DIRLIST < <(find "$BASE_DIR" -mindepth 1 -maxdepth 2 -type d)

TOTAL=${#DIRLIST[@]}
COUNT=0

# ------------------ Main Loop -------------------
for dir in "${DIRLIST[@]}"; do
    COUNT=$((COUNT+1))

    # Progress bar (simple)
    percent=$(( COUNT * 100 / TOTAL ))
    echo -ne "Progress: $percent%  \r"

    name=$(basename "$dir")
    parent=$(dirname "$dir")
    newname=$(fix_name "$name")

    [[ "$name" == "$newname" ]] && continue

    oldpath="$parent/$name"
    newpath="$parent/$newname"

    if [[ -e "$newpath" ]]; then
        echo "WARNING: $newpath exists, skipping $oldpath" | tee -a "$LOGFILE"
        continue
    fi

    if [[ $DRYRUN -eq 1 ]]; then
        echo "[DRY-RUN] $oldpath --> $newpath" | tee -a "$LOGFILE"
    else
        mv "$oldpath" "$newpath"
        echo "$oldpath --> $newpath" | tee -a "$LOGFILE"
    fi
done

echo -e "\n==== Folder Rename Finished at $(date) ====" >> "$LOGFILE"
echo -e "\nDone."
