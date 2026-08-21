#!/bin/bash

# all script need adleast the following parameter from kitodo: -p "(processid)" -t "(processtitle)" -d "${meta.document_type}" -u "${meta.unitIDCUSTOM}"
# -a "${meta.archiveNameCUSTOM}" -s "${meta.stockUnitIDCUSTOM}" -x "${meta.accessrestrict}" -l "${meta.delivery}"

#sourcing library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

# referenced from library
# shellcheck disable=SC2154
tmp_folder="/tmp/kitodo/${kitodo_processid}"

# referenced from library
# shellcheck disable=SC2154
mkdir -p "${tmp_folder}"

# referenced from library
# shellcheck disable=SC2154
output_folder_path="${base_path_ceph}/derivate/derivate_on_demand"

generation_list_path="${tmp_folder}/stuecke.txt"

find_image_files () {
    find "${1}" -type f -and \( -name "*.tiff" -or -name "*.tif" \) > "${generation_list_path}"
    if [ ! -s "${generation_list_path}" ]; then
        echo "No tif(f) images found... Trying with jp(e)g"
        find "${1}" -type f -and \( -name "*.jpg" -or -name "*.jpeg" \) > "${generation_list_path}"
        if [ ! -s "${generation_list_path}" ]; then
            echo "Also no jp(e)g images found... Nothing to generate..."
            exit 1
        fi
    fi
}

# disable shellcheck / used from external library
# shellcheck disable=SC2154
if [[ -d "${base_path_ceph}/${full_sig_path}" ]]; then
    final_ceph_path="${base_path_ceph}/${full_sig_path}"
elif [[ -d "${base_path_ceph}/secure/${full_sig_path}" ]]; then
    final_ceph_path="${base_path_ceph}/secure/${full_sig_path}"
elif [[ -d "${base_path_ceph}/fremdarchivalien/${full_sig_path}" ]]; then
    final_ceph_path="${base_path_ceph}/fremdarchivalien/${full_sig_path}"
elif [[ -d "${base_path_ceph}/secure/fremdarchivalien/${full_sig_path}" ]]; then
    final_ceph_path="${base_path_ceph}/secure/fremdarchivalien/${full_sig_path}"
fi

# shellcheck disable=SC2154
# variable referenced from library
find_image_files "${final_ceph_path}" || exit 1

if [ "${jpg_quality}" == "" ]; then
        jpg_quality=90
fi

# shellcheck disable=SC2154
if [ "${maxsize}" == "" ]; then
        maxsize=1500
fi

# disable shellcheck / used from external library
# shellcheck disable=SC2154
sg "${group}" -c "/usr/bin/python3 /usr/local/bin/hla/generate_derivate.py \
--profile derivate_on_demand \
--outbasefolder ${output_folder_path} \
--maxsize-x ${maxsize} \
--maxsize-y ${maxsize} \
--outquality ${jpg_quality} \
--log_file ${logfile_path} \
--generation_list ${generation_list_path}"

python_exit_code="${?}"

if [[ "${python_exit_code}" -ne 0 ]]; then
        echo "Error in Generator Script!"
        exit "${python_exit_code}"
fi

rm "${generation_list_path}"
rmdir "${tmp_folder}"
