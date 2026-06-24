#!/bin/bash
# see library (lib_hla_kitodo.sh) for needed parameters

# sourcing library and include
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! Please check."
    exit 5
fi

if [[ -z "$kitodo_processtitle" ]]; then
    echo "ERROR: kitodo_processtitle is empty"
    exit 3
fi

# Remove 'Unbekannt_' prefix and get first two path segments
relate_stock="${kitodo_processtitle#Unbekannt_}"
# debug
echo "RELATE_STOCK=[$relate_stock]"
archive=$(echo "$relate_stock" | cut -d'/' -f1)
stock=$(echo "$relate_stock" | cut -d'/' -f2)
echo "ARCHIVE=[$archive]"
echo "STOCK=[$stock]"

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

# validate paths
valid_paths=()

if [ -d "$stock_full_path" ]; then
    valid_paths+=("$stock_full_path")
fi

if [ -d "$stock_secure" ]; then
    valid_paths+=("$stock_secure")
fi

if [ -d "$stock_fremd" ]; then
    valid_paths+=("$stock_fremd")
fi

# Debug output
echo "DEBUG: full=$stock_full_path"
echo "DEBUG: secure=$stock_secure"
echo "DEBUG: fremd=$stock_fremd"

# Exit if non path exists
if [ ${#valid_paths[@]} -eq 0 ]; then
    echo "ERROR: No valid directories found for process $kitodo_processid"
    exit 2
fi

# run find ONLY on valid paths
# Find files and write to generation list
find "${valid_paths[@]}" -type f \( \
    -iname "*.tif" -o -iname "*.tiff" -o \
    -iname "*.jpg" -o -iname "*.jpeg" \
\) > "$generation_list" 2>/dev/null

if [[ -s "$generation_list" ]]; then
    echo "Generation list created successfully: $generation_list"
else
    echo "ERROR: No matching files found or find failed!"
    exit 1
fi

# Success Exit
echo "list_generator finished successfully."
exit 0
	