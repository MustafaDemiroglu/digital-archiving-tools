#!/usr/bin/env bash
#############
# Script Name: secure_exposure_checker.sh
# Version 1.1
# Date 17.08.2026
#
# Description:
#   Checks whether files from a SECURE archive also exist in a NON-SECURE
#   / PUBLIC directory using the same relative path.
#
#   The purpose is to detect files that may have been accidentally published
#   from the secure archive to a public/non-secure server.
#
# Features:
#   1. Asks for directories if they are not supplied as arguments.
#   2. Checks files, not empty directories.
#   3. Supports excluding directories (-e / --except).
#   4. Supports limiting the search to specific subdirectories
#      (-s / --search).
#   5. Handles spaces and special characters in filenames.
#   6. Logs errors and execution summary.
#   7. Writes potentially exposed files to a CSV file.
#
# Example:
#   ./compare_secure_to_nonsecure.sh /archive/secure /server/public
#
#   ./compare_secure_to_nonsecure.sh /archive/secure /server/public \
#       -e thumbs,cache,tmp
#
#   ./compare_secure_to_nonsecure.sh /archive/secure /server/public \
#       -s kunden,products
#
##########

set -euo pipefail

# Date / Output files
DATE=$(date +"%Y-%m-%d_%H-%M-%S")
SCRIPT_NAME=$(basename "$0" .sh)

LOG_FILE="result_${SCRIPT_NAME}_${DATE}.log"
CSV_FILE="exposed_${SCRIPT_NAME}_${DATE}.csv"

# Variables
EXCEPT_DIRS=()
SEARCH_DIRS=()

# Parse arguments
ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in

        -e|--except)
            shift

            if [[ -z "${1:-}" ]]; then
                echo "[ERROR] Missing value for --except"
                exit 1
            fi

            IFS=',' read -ra temp <<< "$1"
            EXCEPT_DIRS+=("${temp[@]}")
            ;;

        -s|--search)
            shift

            if [[ -z "${1:-}" ]]; then
                echo "[ERROR] Missing value for --search"
                exit 1
            fi

            IFS=',' read -ra temp <<< "$1"
            SEARCH_DIRS+=("${temp[@]}")
            ;;

        *)
            ARGS+=("$1")
            ;;
    esac

    shift
done

# Get directories
SECURE_DIR=${ARGS[0]:-}
SERVER_DIR=${ARGS[1]:-}

ask_for_input() {

    local var_name=$1
    local prompt=$2
    local value=${!var_name:-}

    if [[ -z "$value" ]]; then
        read -r -p "$prompt: " value
    fi

    echo "$value"
}

SECURE_DIR=$(ask_for_input SECURE_DIR \
    "Enter path to SECURE directory")

SERVER_DIR=$(ask_for_input SERVER_DIR \
    "Enter path to SERVER/PUBLIC directory")

# Display configuration
echo
echo "================================================="
echo " Secure / Non-Secure File Exposure Check"
echo "================================================="
echo
echo "Secure directory:     $SECURE_DIR"
echo "Non-secure directory: $SERVER_DIR"
echo
echo "Log file:              $LOG_FILE"
echo "CSV file:              $CSV_FILE"
echo
echo "Except dirs: ${EXCEPT_DIRS[*]:-(none)}"
echo "Search dirs: ${SEARCH_DIRS[*]:-(all)}"
echo
echo "-------------------------------------------------"
echo "Checking files..."
echo "-------------------------------------------------"
echo

# Initialize log
{
    echo "Script started at $(date)"
    echo "Secure:     $SECURE_DIR"
    echo "Server: 	  $SERVER_DIR"
    echo "Except:     ${EXCEPT_DIRS[*]:-(none)}"
    echo "Search:     ${SEARCH_DIRS[*]:-(all)}"
    echo "-------------------------------------------------"
} > "$LOG_FILE"

# Initialize CSV
echo '"Relative Path","Secure File","Server File","File Size (bytes)"' \
    > "$CSV_FILE"

# Check directories
if [[ ! -d "$SECURE_DIR" ]]; then

    echo "[ERROR] Secure directory not found: $SECURE_DIR" \
        | tee -a "$LOG_FILE"

    exit 1
fi

if [[ ! -d "$SERVER_DIR" ]]; then

    echo "[ERROR] Digiserver directory not found: $SERVER_DIR" \
        | tee -a "$LOG_FILE"

    exit 1
fi

# Build find paths
FIND_PATHS=()

if [[ ${#SEARCH_DIRS[@]} -gt 0 ]]; then

    for sd in "${SEARCH_DIRS[@]}"; do

        search_path="$SECURE_DIR/$sd"

        if [[ -d "$search_path" ]]; then
            FIND_PATHS+=("$search_path")
        else
            echo "[WARNING] Search directory does not exist: $search_path" \
                | tee -a "$LOG_FILE"
        fi

    done

else

    FIND_PATHS+=("$SECURE_DIR")

fi

# Build exclude arguments
EXCLUDE_ARGS=()

if [[ ${#EXCEPT_DIRS[@]} -gt 0 ]]; then

    for ed in "${EXCEPT_DIRS[@]}"; do

        EXCLUDE_ARGS+=(
            -not -path "*/$ed"
            -not -path "*/$ed/*"
        )

    done

fi

# Counters
SECURE_FILES=0
EXPOSED_FILES=0
ERRORS=0

# Scan SECURE files
while IFS= read -r -d '' secure_file; do

    ((SECURE_FILES+=1))

    # Calculate relative path
    rel_path="${secure_file#$SECURE_DIR/}"

    # Build corresponding Digisever path
    digiserver_file="$SERVER_DIR/$rel_path"

    # Check whether file exists in Digiserver
    if [[ -f "$digiserver_file" ]]; then

        ((EXPOSED_FILES+=1))

        file_size=$(stat -c "%s" "$secure_file" 2>/dev/null || echo "unknown")

        echo "[FOUND] Secure file also exists in NON-SECURE/Digisever/Public:"
        echo "        $rel_path"

        {
            printf '"%s","%s","%s","%s"\n' \
                "$rel_path" \
                "$secure_file" \
                "$digiserver_file" \
                "$file_size"
        } >> "$CSV_FILE"

    fi

done < <(
    find "${FIND_PATHS[@]}" \
        -type f \
        "${EXCLUDE_ARGS[@]}" \
        -print0 \
        2>>"$LOG_FILE"
)

# Summary
{
    echo
    echo "-------------------------------------------------"
    echo "Execution Summary"
    echo "-------------------------------------------------"
    echo "Finished at:       $(date)"
    echo "Secure files:      $SECURE_FILES"
    echo "Exposed files:     $EXPOSED_FILES"
    echo "Errors:            $ERRORS"
    echo
} >> "$LOG_FILE"

# Final output
echo
echo "================================================="
echo "Finished"
echo "================================================="
echo
echo "Secure files checked : $SECURE_FILES"
echo "Potential exposures  : $EXPOSED_FILES"
echo
echo "Log file:"
echo "  $LOG_FILE"
echo
echo "CSV report:"
echo "  $CSV_FILE"
echo

if [[ "$EXPOSED_FILES" -gt 0 ]]; then

    echo "!!! WARNING !!!"
    echo "$EXPOSED_FILES file(s) from SECURE also exist in Nonsecure/Digisever/Public."
    echo "Please review the CSV report."
    echo

else

    echo "OK - No matching secure files were found in NON-SECURE/Digisever/Public."
    echo

fi