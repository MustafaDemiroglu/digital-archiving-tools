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

#if [[ $(find "${final_hdd_path}/" -type d -empty | wc -l) -ne 0 ]]; then
#    echo "Found empty directory, so nothing to do. Please check if everything is fine."
#    exit 3
#fi

# check if final_ceph_path already exist
# referenced from library
# shellcheck disable=SC2154
if [[ -d "${final_ceph_path}" ]]; then
    echo "Destination folder already exist! Manuel intervention required! Get some data for logging..."
    # get all file and folders from hdd / ingest path and sort it
    final_hdd_path_filelist=$(find "${final_hdd_path}" -mindepth 1 | sort)
    # get all file and folders from final ceph path and sort it
    final_ceph_path_filelist=$(find "${final_ceph_path}" -mindepth 1 | sort)
    # count hdd filelist
    final_hdd_path_filelist_length=$(echo "${final_hdd_path_filelist}" | wc -l)
    # count ceph filelist
    final_ceph_path_filelist_length=$(echo "${final_ceph_path_filelist}" | wc -l)
    # check if both list have the same length
    if [[ "${final_hdd_path_filelist_length}" -ne "${final_ceph_path_filelist_length}" ]]; then
        echo "Different number of files in both folders!"
        echo "hdd / ingest: ${final_hdd_path_filelist_length}"
        echo "ceph: ${final_ceph_path_filelist_length}"
    else
        echo "Same number of files in both folder: ${final_hdd_path_filelist_length}"
    fi

    # check if first entry of hdd filelist is also in ceph filelist
    if  grep "$(echo "${final_hdd_path_filelist}" | head -n 1)" "${final_ceph_path_filelist}"; then
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
