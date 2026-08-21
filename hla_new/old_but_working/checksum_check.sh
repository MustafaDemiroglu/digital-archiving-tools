#!/bin/bash
# (processid) (processtitle) ${meta.unitIDCUSTOM} ${meta.archiveNameCUSTOM} ${meta.stockUnitIDCUSTOM} ${meta.accessrestrict}

# sourcing library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

# search for current folder of vze and filling variables (folder_path, full_hdd_folders, hdd_root_folder and hdd_sub_folder)
search_folder_vze

# disable shellcheck / used from external library
# overwrite variable from hla library and use explicit path for checksum file
# shellcheck disable=SC2154
md5_file="${base_path_manifest}/${meta_delivery}.md5"

if [[ ! -f "${md5_file}" ]]; then
    echo "md5 file not found, please check the following path: ${md5_file} Aborting."
    exit 2
fi

# disable shellcheck / used from external library
# shellcheck disable=SC2154
to_check=$(grep "${full_sig_path}/" "${md5_file}")

# disable shellcheck / used from external library
# shellcheck disable=SC2154
cd "${base_path_ceph}" || exit 1
echo "${to_check}" | md5sum --check
# disable shellcheck for better reading with pipe
# shellcheck disable=SC2181
if [[ "${?}" -ne 0 ]]; then
    echo "Error by checking checksums, please check! Aborting."
    exit 6
else
    echo "Successfully checked checksums"
fi
