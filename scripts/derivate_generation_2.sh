#!/bin/bash

# all script need adleast the following parameter from kitodo: -p "(processid)" -t "(processtitle)" -d "${meta.document_type}" -u "${meta.unitIDCUSTOM}"
# -a "${meta.archiveNameCUSTOM}" -s "${meta.stockUnitIDCUSTOM}" -x "${meta.accessrestrict}" -l "${meta.delivery}"

# sourcing library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

# disable shellcheck / used from external library
# shellcheck disable=SC2154
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

# shellcheck disable=SC2154
# variable referenced from library
hdd_folder_path="${folder_path}"
find_image_files "${hdd_folder_path}" || exit 1

# generate list for preview generation (only first image from generation list)
head -n 1 "${generation_list_path}" > "${generation_list_path_only_preview}"

if [ "${jpg_quality}" == "" ]; then
        jpg_quality=90
fi

if [ "${maxsize_x}" == "" ]; then
        maxsize_x=3500
fi

if [ "${maxsize_y}" == "" ]; then
        maxsize_y=3500
fi

# disable shellcheck / used from external library
# generate derivate
# shellcheck disable=SC2154
sg "${group}" -c "/usr/bin/python3 $(dirname "${0}")/generate_derivate.py \
--profile sifi_git \
--max_threads 1 \
--storage_path ${hdd_folder_path} \
--outbasefolder ${output_folder_path} \
--outbasefolder_max max \
--outbasefolder_thumb thumbs \
--log_file ${logfile_path} \
--generation_list ${generation_list_path}"

generate_derivate_exit_code="${?}"

# disable shellcheck / used from external library
# generate single preview from first image
# shellcheck disable=SC2154
sg "${group}" -c "/usr/bin/python3 $(dirname "${0}")/generate_derivate.py \
--profile only_preview \
--max_threads 1 \
--storage_path ${hdd_folder_path} \
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
