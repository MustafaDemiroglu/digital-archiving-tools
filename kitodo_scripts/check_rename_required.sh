#!/bin/bash
# see library for parameters

# Source Kitodo library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

# search for current folder of vze and filling variables (folder_path, full_hdd_folders, hdd_root_folder and hdd_sub_folder)
# search for kitodo_metadata_path, kitodo_processid
search_folder_vze

RENAME_FILE="${kitodo_metadata_path}/${kitodo_processid}/rename.txt"

if [[ -f "${RENAME_FILE}" ]]; then
    echo "[WARN] rename.txt found: ${RENAME_FILE}"
    echo "[WARN] A rename action may be required."
    echo "[WARN] Please manually check whether the process requires renaming."
    echo "[WARN] Workflow will be stopped. Manual intervention is required."
    exit 1
fi

echo "[INFO] No rename.txt found. No manual rename check required."
echo "[INFO] Workflow can continue."
exit 0