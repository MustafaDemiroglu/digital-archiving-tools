#!/bin/bash
# see library (lib_hla_kitodo.sh) for parameters

set -euo pipefail

# sourcing library and include
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! Please check."
    exit 5
fi

# Remove 'Unbekannt_' prefix and get first two path segments
relate_stock="${kitodo_processtitle#Unbekannt_}"
archive=$(echo "$relate_stock" | cut -d'/' -f1)
stock=$(echo "$relate_stock" | cut -d'/' -f2)

# Construct paths
output_folder_path="${base_path_ceph}/derivate_on_demand/07_${archive}_${stock}"

pad_number() {
    printf "%04d" "$((10#$1))"
}

get_lowest_dirs() {
    find "$output_folder_path" -type d | while read -r dir; do
        if ! find "$dir" -mindepth 1 -type d | read; then
            echo "$dir"
        fi
    done
}

rename_file() {
    local dir="$1"

    for file in "$dir"/*; do
        [ -f "$file" ] || continue

        fname=$(basename "$file")

        if [[ "$fname" =~ (.*_)([0-9]+)(\.[^.]+)$ ]]; then
            prefix="${BASH_REMATCH[1]}"
            num="${BASH_REMATCH[2]}"
            ext="${BASH_REMATCH[3]}"

            padded=$(pad_number "$num")

            newname="$dir/${prefix}${padded}${ext}"

            if [[ "$file" != "$newname" ]]; then
                mv "$file" "$newname"
                echo "Renamed file: $file -> $newname"
            fi
        fi
    done
}

while read -r dir; do
    rename_file "$dir"
done < <(get_lowest_dirs)

echo "Rename Files Process finished successfully."
exit 0