#!/bin/bash
# see library for needed parameters

# sourcing library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

# search for currernt folder of vze and filling variables (folder_path, full_hdd_folders, hdd_root_folder and hdd_sub_folder)
search_folder_vze

# check if checksum file was already successfully moved
# disable shellcheck variable exported in library
# shellcheck disable=SC2154
if [[ -f "${base_path_hdd_ingest_ceph}/${hdd_root_folder}/.checksum_file_successfully_uploaded" ]]; then
    echo "Checksum file was already uploaded, nothing to do."
    exit 0
fi

# shellcheck disable=SC2154
md5_file="${base_path_hdd_ingest_ceph}/${hdd_root_folder}/${meta_delivery}.md5"
if [[ ! -f "${md5_file}" ]]; then
    echo "md5 file not found under ${md5_file}, please check! Aborting."
    exit 2
fi

# disable shellcheck variable exported in library
# shellcheck disable=SC2154
# running upload checksum library file with parameters
"$(dirname "${0}")"/upload_checksum_file_lib.sh "${md5_file}" "${kitodo_processid}" "${kitodo_processtitle}" "${meta_delivery}"