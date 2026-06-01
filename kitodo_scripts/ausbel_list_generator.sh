#!/bin/bash
# see library (lib_hla_kitodo.sh) for needed parameters

# sourcing library and include
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! Please check."
    exit 5
fi

# Remove 'Unbekannt_' prefix and get first two path segments
relate_stock="${processtitle#Unbekannt_}"
archive=$(echo "$relate_stock" | cut -d'/' -f1)
stock=$(echo "$relate_stock" | cut -d'/' -f2)

# Construct paths
stock_full_path="${base_path_ceph}/${archive}/${stock}"
stock_secure="${base_path_ceph}/secure/${archive}/${stock}"
stock_fremd="${base_path_ceph}/fremdarchivalien/${archive}/${stock}"
kitodo_process_folder="${kitodo_metadata_path}/${kitodo_processid}"
generation_list="${kitodo_process_folder}/generierung.list"

# Clear old generation list if exists
if [ -f "$generation_list" ]; then
	> "$generation_list"
fi

# Find files and write to generation list
if find "$stock_full_path" "$stock_secure" "$stock_fremd" -type f > "$generation_list" 2>/dev/null; then
	echo "Generation list created succesfully: $generation_list"
else
	echo "Error: Failed to create generation list!"
	exit 1
fi

# Success Exit
echo "list_generator finished successfully."
exit 0
	