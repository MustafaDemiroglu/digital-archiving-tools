#!/bin/bash
# see library for needed parameters

# sourcing library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

# Ensure real folder detection (secure/fremdarchivalien safe)
search_folder_vze

if [[ -z "${folder_path}" ]]; then
    echo "Could not determine real hdd storage folder. Aborting."
    exit 2
fi

kitodo_process_folder="${kitodo_metadata_path}/${kitodo_processid}/images"

cd "${kitodo_process_folder}" || exit 1

tmp_folder="/tmp/kitodo/${kitodo_processid}"
mkdir -p "${tmp_folder}"
output_folder_path="${kitodo_process_folder}"
generation_list_path="${tmp_folder}/stuecke.txt"
generation_list_path_only_preview="${tmp_folder}/stuecke_preview.txt"

find_image_files () {
    find "${1}" -type f -and \( -name "*.tiff" -or -name "*.tif" \) | sort > "${generation_list_path}"
    if [ ! -s "${generation_list_path}" ]; then
        echo "No tif(f) images found... Trying with jp(e)g"
        find "${1}" -type f -and \( -name "*.jpg" -or -name "*.jpeg" \) | sort > "${generation_list_path}"
        if [ ! -s "${generation_list_path}" ]; then
            echo "Also no jp(e)g images found... Nothing to generate..."
            exit 1
        fi
    fi
}

# variable referenced from library
find_image_files "${folder_path}"

# generate list for preview generation (only first image from generation list)
head -n 1 "${generation_list_path}" > "${generation_list_path_only_preview}"

# generate derivate
sg "${group}" -c "/usr/bin/python3 $(dirname "${0}")/generate_derivate.py \
--profile sifi_git \
--max_threads 1 \
--storage_path ${folder_path} \
--outbasefolder ${output_folder_path} \
--outbasefolder_max max \
--outbasefolder_thumb thumbs \
--log_file ${logfile_path} \
--generation_list ${generation_list_path}"

generate_derivate_exit_code="${?}"

# generate single preview from first image
sg "${group}" -c "/usr/bin/python3 $(dirname "${0}")/generate_derivate.py \
--profile only_preview \
--max_threads 1 \
--storage_path ${folder_path} \
--outbasefolder ${output_folder_path} \
--outbasefolder_preview thumbs \
--log_file ${logfile_path} \
--generation_list ${generation_list_path_only_preview}"

generate_preview_exit_code="${?}"

if [[ "${generate_derivate_exit_code}" -ne 0 ]]; then
        echo "Error in Generator Script!"
        exit "${generate_derivate_exit_code}"
fi

if [[ "${generate_preview_exit_code}" -ne 0 ]]; then
        echo "Error by preview generation!"
        exit "${generate_derivate_exit_code}"
fi

rm "${generation_list_path}"
rm "${generation_list_path_only_preview}"
rmdir "${tmp_folder}"

echo "Derivate generation completed successfully."
exit 0 