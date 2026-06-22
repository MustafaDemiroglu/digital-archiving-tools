#!/bin/bash
# see library (lib_hla_kitodo.sh) for parameters

set -euo pipefail

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
output_folder_path="${base_path_ceph}/derivate_on_demand/${stock}_ausbelichtung"

TESTCHART="/media/cepheus/ingest/testcharts_bestandsblatt/testcharts/_0000.jpg"

# true  = only add testchart if folder has more than 2 files
# false = always add testchart if matching file exists
ONLY_IF_MORE_THAN_TWO_FILES=true

get_lowest_dirs() {
    find "$output_folder_path" -type d | while read -r dir; do
        if ! find "$dir" -mindepth 1 -type d | read; then
            echo "$dir"
        fi
    done
}

add_testchart() {
    local dir="$1"

    # count files
    file_count=$(find "$dir" -maxdepth 1 -type f | wc -l)

    # optional restriction
    if [[ "$ONLY_IF_MORE_THAN_TWO_FILES" == true ]]; then
        if [[ "$file_count" -le 2 ]]; then
            echo "Skipping $dir (only $file_count files)"
            return
        fi
    fi

    for file in "$dir"/*; do
        [ -f "$file" ] || continue

        filename=$(basename "$file")

        if [[ "$filename" =~ ^(.*_)([0-9]+)(\.[^.]+)$ ]]; then
            prefix="${BASH_REMATCH[1]}"
            extension="${BASH_REMATCH[3]}"

            newfile="${dir}/${prefix}00000${extension}"

            if [[ ! -f "$newfile" ]]; then
                cp "$TESTCHART" "$newfile"
                echo "Added TESTCHART: $newfile"
            else
                echo "TESTCHART already exists: $newfile"
            fi

            return
        fi
    done

    echo "No suitable file found in $dir"
}

if [[ ! -f "$TESTCHART" ]]; then
    echo "ERROR: Testchart not found: $TESTCHART"
    exit 1
fi

while read -r dir; do
    add_testchart "$dir"
done < <(get_lowest_dirs)

echo "Add Testchart Process finished successfully."
exit 0