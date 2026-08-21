#!/bin/bash
# (processid) (processtitle) ${meta.unitIDCUSTOM} ${meta.archiveNameCUSTOM} ${meta.stockUnitIDCUSTOM} ${meta.accessrestrict}

# sourcing library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

#search for currernt folder of vze and filling variables (folder_path, full_hdd_folders, hdd_root_folder and hdd_sub_folder)
search_folder_vze

#check if vze has access restriction
# disable shellcheck / used from external library
# shellcheck disable=SC2154
if [ "${vze_accessrestrict}" == "true" ]; then
    #move all secure file to secure structure in ceph
    final_ceph_path="${base_path_ceph}/secure/${hdd_sub_folder}/${full_sig_path}"
    final_hdd_path="${base_path_hdd_ingest_ceph}/${hdd_root_folder}/secure/${hdd_sub_folder}/${full_sig_path}"
else
    final_ceph_path="${base_path_ceph}/${hdd_sub_folder}/${full_sig_path}"
    final_hdd_path="${base_path_hdd_ingest_ceph}/${hdd_root_folder}/${hdd_sub_folder}/${full_sig_path}"
fi

# Possible Ceph destination paths independent of access restriction.
# This is needed because the same transfer can arrive once as secure
# and another time as non-secure.
ceph_secure_path="${base_path_ceph}/secure/${hdd_sub_folder}/${full_sig_path}"
ceph_non_secure_path="${base_path_ceph}/${hdd_sub_folder}/${full_sig_path}"

#if [[ $(find "${final_hdd_path}/" -type d -empty | wc -l) -ne 0 ]]; then
#    echo "Found empty directory, so nothing to do. Please check if everything is fine."
#    exit 3
#fi

# Check if final_ceph_path OR the corresponding path with the opposite access restriction already exists.
# referenced from library
# shellcheck disable=SC2154
# Secure/non-secure status must NOT be relevant for duplicate detection.

existing_ceph_path=""

if [[ -d "${ceph_secure_path}" && -d "${ceph_non_secure_path}" ]]; then
    echo "Destination folder exists in BOTH secure and non-secure structures!"
    echo "Secure:     ${ceph_secure_path}"
    echo "Non-secure: ${ceph_non_secure_path}"
    echo "Manual intervention required!"
    exit 1

elif [[ -d "${ceph_secure_path}" ]]; then
    existing_ceph_path="${ceph_secure_path}"
    echo "Destination folder already exists in secure structure!"
    echo "Existing path: ${existing_ceph_path}"
    echo "Incoming transfer path: ${final_hdd_path}"
    echo "Manual intervention required! Get some data for logging..."

elif [[ -d "${ceph_non_secure_path}" ]]; then
    existing_ceph_path="${ceph_non_secure_path}"
    echo "Destination folder already exists in non-secure structure!"
    echo "Existing path: ${existing_ceph_path}"
    echo "Incoming transfer path: ${final_hdd_path}"
    echo "Manual intervention required! Get some data for logging..."
fi

if [[ -n "${existing_ceph_path}" ]]; then

    # get all file and folders from hdd / ingest path and sort it
    final_hdd_path_filelist=$(find "${final_hdd_path}" -mindepth 1 | sort)

    # get all file and folders from the existing Ceph path and sort it
    final_ceph_path_filelist=$(find "${existing_ceph_path}" -mindepth 1 | sort)

    # count hdd filelist
    final_hdd_path_filelist_length=$(echo "${final_hdd_path_filelist}" | wc -l)

    # count ceph filelist
    final_ceph_path_filelist_length=$(echo "${final_ceph_path_filelist}" | wc -l)

    # check if both lists have the same length
    if [[ "${final_hdd_path_filelist_length}" -ne "${final_ceph_path_filelist_length}" ]]; then
        echo "Different number of files in both folders!"
        echo "hdd / ingest: ${final_hdd_path_filelist_length}"
        echo "ceph: ${final_ceph_path_filelist_length}"
    else
        echo "Same number of files in both folders: ${final_hdd_path_filelist_length}"
    fi

    # check if first entry of hdd filelist is also in ceph filelist
    if grep -Fqx "$(echo "${final_hdd_path_filelist}" | head -n 1)" <<< "${final_ceph_path_filelist}"; then
        echo "First file of hdd / ingest filelist was found in ceph filelist!"
    else
        echo "First file of hdd / ingest filelist was NOT found in ceph filelist."
    fi

    # exit script with error code one for manual intervention
    exit 1
else
    sg "${group}" -c "mkdir -vp ${final_ceph_path}"
fi

# moving files to ceph, recursively, without links, keep modification time, force permissions, force group, ignore existing file and delete file after successful transfer
if ! rsync -rtv --perms --chmod=D2770,F0660 --chown=:hladigi --ignore-existing --remove-source-files "${final_hdd_path}/" "${final_ceph_path}"; then
    echo "Error by moving files with rsync!"
    exit 1
fi

if [[ $(find "${final_hdd_path}/" -type d ! -empty | wc -l) -eq 0 ]]; then
    echo "empty source folder: ${final_hdd_path}/"
#    rmdir "${final_hdd_path}/"
else
    echo "Source folder not empty, please check! Aborting."
    exit 4
fi

# disable shellcheck / used from external library
# shellcheck disable=SC2154
echo "End of script ${script_name}"
