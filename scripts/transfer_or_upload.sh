#!/bin/bash

# REQUIREMENTS:
# - jq, rsync, dos2unix, sed, awk, basename, md5sum, tee
# - SSH key must be already configured on the system

# Load common configuration (lock, unlock functions etc.)
. /etc/hla/common.conf

# Acquire exclusive lock to prevent multiple instances
exlock_now || exit 1

# Prompt for source folder
read -rp "Please enter the full path of the folder you want to upload: " source_folder

# Verify source directory exists
if [[ ! -d "${source_folder}" ]]; then
    echo "Error: Directory does not exist."
    unlock
    exit 1
fi

# Prompt for target name on server
read -rp "Please enter the name of the target folder on the server: " target_name

# Prepare related filenames
md5_file="${source_folder}/${target_name}.md5"
log_file="${source_folder}/${target_name}.log"
started_marker="${source_folder}/.automatic_upload_started"
complete_marker="${source_folder}/.automatic_upload_complete"

# Open log file and start logging with timestamps
exec > >(tee -a "${log_file}") 2>&1
echo "==== Starting upload process on $(date) ===="
echo "Source folder: ${source_folder}"
echo "Target folder on server: ${target_name}"
echo "MD5 file: ${md5_file}"
echo "Log file: ${log_file}"
echo ""

# Check for already completed upload
if [[ -f "${complete_marker}" ]]; then
    echo "[INFO] This folder has already been uploaded. Exiting."
    unlock
    exit 0
fi

# If upload was already started, continue with same target name
if [[ -f "${started_marker}" ]]; then
    echo "[INFO] Upload already started previously. Resuming..."
    previous_name=$(<"${started_marker}")
    echo "[INFO] Continuing with target name: ${previous_name}"
else
    echo "${target_name}" > "${started_marker}"
    echo "[INFO] Upload process started for new folder: ${target_name}"
fi

# Create MD5 file if it does not exist yet
if [[ ! -f "${md5_file}" ]]; then
    echo "[INFO] Creating MD5 file: ${md5_file}"
    # Show each file being processed
    find "${source_folder}" -type f ! -name "$(basename ${md5_file})" | while read -r file; do
        echo "[MD5] Calculating: ${file}"
        md5sum "${file}"
    done > "${md5_file}"
    echo "[INFO] MD5 file created successfully."
else
    echo "[INFO] MD5 file already exists: ${md5_file}"
fi

# Rsync upload with retry mechanism
trap "echo [ERROR] Interrupted by user! Exiting.; unlock; exit 1" SIGINT SIGTERM

RSYNC_MAX_RETRIES=20
RSYNC_EXIT_STATUS=1
counter=0

while [[ "${RSYNC_EXIT_STATUS}" -ne 0 && "${counter}" -lt "${RSYNC_MAX_RETRIES}" ]]; do
    counter=$((counter+1))
    echo "[INFO] Attempt #${counter} to upload data using rsync..."
    rsync -av --progress --perms --chmod=D2770,F0660 --chown=:hladigi \
        --exclude '$RECYCLE.BIN' --exclude 'System Volume Information' \
        -e "ssh -i /home/hladigiworker/.ssh/id_ed25519_automatic -o ConnectTimeout=60 -o ServerAliveInterval=30 -o ServerAliveCountMax=6" \
        "${source_folder}/" "hladigiingest@vhrz1653.hrz.uni-marburg.de:/${target_name}"

    RSYNC_EXIT_STATUS=$?
    echo "[INFO] rsync exit status: ${RSYNC_EXIT_STATUS}"
    if [[ "${RSYNC_EXIT_STATUS}" -ne 0 ]]; then
        echo "[WARN] rsync failed, will retry after short pause..."
        sleep 5
    fi
done

if [[ "${RSYNC_EXIT_STATUS}" -eq 0 ]]; then
    echo "[SUCCESS] Upload completed successfully!"
    rm -f "${started_marker}"
    touch "${complete_marker}"
else
    echo "[ERROR] Reached maximum retry attempts. Upload failed."
    unlock
    exit 1
fi

echo "[INFO] Process completed on $(date)"
unlock