#!/bin/bash
# (processid) (processtitle) ${meta.unitIDCUSTOM} ${meta.archiveNameCUSTOM} ${meta.stockUnitIDCUSTOM} ${meta.accessrestrict}

# sourcing library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

# populate folder variables (folder_path, full_hdd_folders, hdd_root_folder and hdd_sub_folder) through search function defined in lib_hla_kitodo
search_folder_vze

is_fremdarchivalien="false"

# disable shellcheck / used from external library
# shellcheck disable=SC2154
if [[ -d "${base_path_ceph}/${full_sig_path}" ]]; then
    final_ceph_path="${base_path_ceph}/${full_sig_path}"
    final_netapp_path="${netapp_path}/${additional_output_folder_netapp}/${full_sig_path}"
elif [[ -d "${base_path_ceph}/secure/${full_sig_path}" ]]; then
    final_ceph_path="${base_path_ceph}/secure/${full_sig_path}"
    final_netapp_path="${netapp_path}/NO_FORBIDDEN/${full_sig_path}"
    vze_accessrestrict="true"
elif [[ -d "${base_path_ceph}/fremdarchivalien/${full_sig_path}" ]]; then
    final_ceph_path="${base_path_ceph}/fremdarchivalien/${full_sig_path}"
    final_netapp_path="${netapp_path}/NO_FORBIDDEN/${full_sig_path}"
    is_fremdarchivalien="true"
elif [[ -d "${base_path_ceph}/secure/fremdarchivalien/${full_sig_path}" ]]; then
    final_ceph_path="${base_path_ceph}/secure/fremdarchivalien/${full_sig_path}"
    final_netapp_path="${netapp_path}/NO_FORBIDDEN/${full_sig_path}"
    is_fremdarchivalien="true"
else
    echo "Nothing found for symlinking, please check! aborting."
    exit 1
fi

# disable shellcheck / used from external library
# shellcheck disable=SC2154
cd "${kitodo_metadata_path}/${kitodo_processid}/images/" || exit 1

echo "Creating Symlinks"
# disable shellcheck / used from external library
# shellcheck disable=SC2154
if [ -d "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_tiff_name}" ]; then
    echo "Deleting folder ${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_tiff_name} to replace with symlinks"
    if ! rmdir "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_tiff_name}"; then
        echo "folder not empty, so not deleting it! Aborting."
        exit 1
    fi
fi

# disable shellcheck / used from external library
# shellcheck disable=SC2154
if [[ "${kitodo_processtitle}" =~ ^Unbekannt_.* ]] || [[ "${kitodo_processtitle}" =~ ^Multimatch_.* ]] || [[ "${vze_accessrestrict}" == "true" ]] || [[ "${is_fremdarchivalien}" == "true" ]]; then
    echo "Unknown vze, Multimatch, fremdarchivalien or secure, skipping symlink to NetApp"
else
    echo "Creating folder structure in netapp folder: ${final_netapp_path}/${kitodo_img_thumb_name}"
    sg "${group}" -c "mkdir -p ${final_netapp_path}/${kitodo_img_thumb_name}"
    if [ -d "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_max_name}" ]; then
        echo "Deleting folder ${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_max_name} to replace with symlinks"
        if ! rmdir "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_max_name}"; then
            echo "folder not empty, so not deleting it! Aborting."
            exit 1
        fi
    fi
    if [ -d "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_thumb_name}" ]; then
        echo "Deleting folder ${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_thumb_name} to replace with symlinks"
        if ! rmdir "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_thumb_name}"; then
            echo "folder not empty, so not deleting it! Aborting."
            exit 1
        fi
    fi
    echo "Creating NetApp Symlink from ${final_netapp_path} to ${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_max_name}"
    ln -s "${final_netapp_path}" "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_max_name}"
    echo "Creating NetApp Symlink from ${final_netapp_path}/${kitodo_img_thumb_name} ${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_thumb_name}"
    ln -s "${final_netapp_path}/${kitodo_img_thumb_name}" "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_thumb_name}"
fi


echo "Creating Ceph Symlink from ${final_ceph_path} ${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_tiff_name}"
ln -s "${final_ceph_path}" "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_tiff_name}"
