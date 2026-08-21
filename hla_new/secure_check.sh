#!/bin/bash
# (processid) (processtitle) ${meta.unitIDCUSTOM} ${meta.archiveNameCUSTOM} ${meta.stockUnitIDCUSTOM} ${meta.accessrestrict}

# sourcing library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

# search for currernt folder of vze and filling variables (folder_path, full_hdd_folders, hdd_root_folder and hdd_sub_folder)
search_folder_vze

# disable shellcheck / used from external library
# shellcheck disable=SC2154
#check if vze has access restriction
if [ "${vze_accessrestrict}" == "true" ]; then
    if [[ -d "${base_path_hdd_ingest_ceph}/${hdd_root_folder}/secure/${hdd_sub_folder}/${full_sig_path}/" ]]; then
        echo "Folder ${hdd_sub_folder}/${full_sig_path}/ already exists in secure. Nothing to do."
        exit 0
    fi
    md5_file="${base_path_hdd_ingest_ceph}/${hdd_root_folder}/${meta_delivery}.md5"
    if [[ ! -f "${md5_file}" ]]; then
        echo "md5 file not found under ${md5_file}, please check! Aborting."
        exit 2
    fi
    if [[ $(find "${base_path_hdd_ingest_ceph}/${full_hdd_folders}/${full_sig_path}/" -type d -empty | wc -l) -ne 0 ]]; then
        echo "Found empty directory, so nothing to do. Please check if everything is fine."
        exit 3
    fi
    #create secure folder structure
    sg "${group}" -c "mkdir -p ${base_path_hdd_ingest_ceph}/${hdd_root_folder}/secure/${hdd_sub_folder}/${full_sig_path}"
    #move all files from current vze folder to secure
    mv -v "${base_path_hdd_ingest_ceph}/${full_hdd_folders}/${full_sig_path}/"* "${base_path_hdd_ingest_ceph}/${hdd_root_folder}/secure/${hdd_sub_folder}/${full_sig_path}/"
    echo "--- Matched lines of md5file (before sed) ---"
    grep "${full_sig_path}/" "${md5_file}"
    #correct paths in md5 file (only writing to logfile too much data)
    (
        # acquire file lock for md5file or fail after 300 seconds
        flock --exclusive --timeout 300 200 || exit 1
        sed -i "s=${full_sig_path}/=secure/${full_sig_path}/=g" "${md5_file}"
    ) 200>"${md5_file}.lock"
    echo "--- Matched lines of md5file (after sed) ---"
    grep "${full_sig_path}/" "${md5_file}"
    if [[ $(find "${base_path_hdd_ingest_ceph}/${full_hdd_folders}/${full_sig_path}/" -type d ! -empty | wc -l) -eq 0 ]]; then
        echo "Removing empty source folder: ${base_path_hdd_ingest_ceph}/${full_hdd_folders}/${full_sig_path}/"
        rmdir "${base_path_hdd_ingest_ceph}/${full_hdd_folders}/${full_sig_path}/"
    else
        echo "Source folder not empty, please check! Aborting."
        exit 4
    fi
    echo "End of script ${script_name}"
fi
