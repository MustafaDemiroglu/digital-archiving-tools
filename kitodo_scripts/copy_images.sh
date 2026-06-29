#!/bin/bash
# see library for parameters

# sourcing library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

# search for currernt folder of vze and filling variables (folder_path, full_hdd_folders, hdd_root_folder and hdd_sub_folder)
search_folder_vze

final_kitodo_image_path="${kitodo_metadata_path}/${kitodo_processid}/images"
final_image_path="/media/cepheus/derivate_on_demand/${meta_delivery}/secure/${full_sig_path}"
final_thumb_path="${final_image_path}/${kitodo_img_thumb_name}"

echo "Creating folder structure: ${final_image_path}"
sg "${group}" -c "mkdir -vp ${final_image_path}"
echo "Copying max images to final structure"
rsync -a --ignore-existing "${final_kitodo_image_path}/${kitodo_img_max_name}/" "${final_image_path}/"
echo "Max images copied successfully."

echo "Creating thumbnails folder structure: ${final_thumb_path}"
sg "${group}" -c "mkdir -vp ${final_thumb_path}"
echo "Copying thumbnails to final structure"
rsync -a --ignore-existing "${final_kitodo_image_path}/${kitodo_img_thumb_name}/" "${final_thumb_path}/"
echo "Thumbnails copied successfully."	
	
if ! find "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_tiff_name}" -type f -delete; then
    echo "Error by deleting tiff working copy files! Aborting."
    exit 1
elif ! find "${kitodo_metadata_path}/${kitodo_processid}/images/${kitodo_img_tiff_name}" -mindepth 1 -type d -delete; then
    echo "Error by deleting empty directories! Aborting."
    exit 1
fi