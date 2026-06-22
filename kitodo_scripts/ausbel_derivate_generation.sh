#!/bin/bash
# see library (lib_hla_kitodo.sh) for parameters

# sourcing library and include
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

# Remove 'Unbekannt_' prefix and get first two path segments
relate_stock="${kitodo_processtitle#Unbekannt_}"
archive=$(echo "$relate_stock" | cut -d'/' -f1)
stock=$(echo "$relate_stock" | cut -d'/' -f2)

# Construct paths
kitodo_process_folder="${kitodo_metadata_path}/${kitodo_processid}"
generation_list="${kitodo_process_folder}/generation.list"
output_folder_path="${base_path_ceph}/derivate_on_demand/${stock}_ausbelichtung"
logfile="${kitodo_process_folder}/generate_derivate.log"

# Clear old log if exists
if [ -f "$logfile" ]; then
	> "$logfile"
fi

mkdir -p "${output_folder_path}"

# Set group ownership to hladigi, ignore errors if not permitted
if ! chgrp -R hladigi "$output_folder_path" 2>/dev/null; then
    echo "WARN: Could not change group to hladigi (not permitted?)"
fi

# permissions for Kitodo + manual access. Try to fix permissions, but do NOT fail if not allowed
if ! chmod -R 775 "$output_folder_path" 2>/dev/null; then
    echo "WARN: Could not change permissions for $output_folder_path (not owner?)"
fi

# check list 
if [ ! -s "${generation_list}" ]; then
    echo "ERROR: No list found or No images are in the list"
	exit 1
fi
       

# Generate derivate with pyhthon script
sg "${group}" -c "/usr/bin/python3 /usr/local/bin/hla/generate_derivate.py \
--profile ausbelichtung \
--outbasefolder ${output_folder_path} \
--log_file ${logfile} \
--generation_list ${generation_list}"

generate_preview_exit_code="${?}"

if [[ "${generate_preview_exit_code}" -ne 0 ]]; then
        echo "Error in Derivate Generator Script!"
        exit "${generate_preview_exit_code}"
else
	echo "SUCCESS: Derivate generated sucessfully"
fi

# Success Exit
echo "Script finished its Job successfully."
exit 0