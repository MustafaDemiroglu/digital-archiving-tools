#!/bin/bash
# all script need adleast the following parameter from kitodo: -p "(processid)" -t "(processtitle)" -d "${meta.document_type}" -u "${meta.unitIDCUSTOM}" -a "${meta.archiveNameCUSTOM}" -s "${meta.stockUnitIDCUSTOM}" -x "${meta.accessrestrict}"

# sourcing library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

# search for currernt folder of vze and filling variables (folder_path, full_hdd_folders, hdd_root_folder and hdd_sub_folder)
search_folder_vze

# disable shellcheck / used from external library
# shellcheck disable=SC2154
final_kitodo_image_path="${kitodo_metadata_path}/${kitodo_processid}/images"
# disable shellcheck / used from external library
# shellcheck disable=SC2154
final_netapp_path_new="${netapp_path}/${additional_output_folder_netapp}/${full_sig_path}"

# disable shellcheck / used from external library
# shellcheck disable=SC2154
if [[ "${kitodo_processtitle}" =~ ^Unbekannt_.* ]] || [[ "${kitodo_processtitle}" =~ ^Multimatch_.* ]] || [[ "${vze_accessrestrict}" == "true" ]] || [[ "${is_fremdarchivalien}" == "true" ]]; then
    echo "Unknown vze, multimatch, fremdarchivalien or secure, skipping moving and symlink to NetApp"
else
    echo "Creating folder structure in netapp folder: ${final_netapp_path_new}"
    sg "${group}" -c "mkdir -p ${final_netapp_path_new}/${kitodo_img_thumb_name}"
    echo "Moving derivate to final structure in NetApp"
    mv -n -v "${final_kitodo_image_path}/${kitodo_img_max_name}/"* "${final_netapp_path_new}"
    mv -n -v "${final_kitodo_image_path}/${kitodo_img_thumb_name}/"* "${final_netapp_path_new}/${kitodo_img_thumb_name}"
    if [ -d "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_max_name}" ]; then
        echo "Deleting folder ${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_max_name} to replace with symlinks"
        if ! rmdir "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_max_name}"; then
            echo "folder not empty, so not deleting it! Aborting."
            exit 1
        fi
    fi
    if [ -d "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_thumb_name}" ]; then
        echo "Deleting folder ${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_thumb_name} to replace with symlinks"
        if  ! rmdir "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_thumb_name}"; then
            echo "folder not empty, so not deleting it! Aborting."
            exit 1
        fi
    fi
    echo "Creating NetApp Symlink from ${final_netapp_path_new} to ${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_max_name}"
    ln -s "${final_netapp_path_new}" "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_max_name}"
    echo "Creating NetApp Symlink from ${final_netapp_path}/${kitodo_img_thumb_name} ${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_thumb_name}"
    ln -s "${final_netapp_path_new}/${kitodo_img_thumb_name}" "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_thumb_name}"
fi

# variable used from library
# shellcheck disable=SC2154
if ! find "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_tiff_name}" -type f -delete; then
    echo "Error by deleting tiff working copy files! Aborting."
    exit 1
elif ! find "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_tiff_name}" -mindepth 1 -type d -delete; then
    echo "Error by deleting empty directories! Aborting."
    exit 1
fi