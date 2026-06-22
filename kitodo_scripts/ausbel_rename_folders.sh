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

pad_number() {
    printf "%05d" "$((10#$1))"
}

get_lowest_dirs() {
    find "$output_folder_path" -type d | while read -r dir; do
        if ! find "$dir" -mindepth 1 -type d | read; then
            echo "$dir"
        fi
    done
}

rename_folder() {
    local dir="$1"

    local base
    base=$(basename "$dir")

    local parent
    parent=$(dirname "$dir")

    # Skip folders without numbers
    if [[ ! "$base" =~ [0-9] ]]; then
        return
    fi

    # Pure digits
    if [[ "$base" =~ ^[0-9]+$ ]]; then
        padded=$(pad_number "$base")

        if [[ "$base" != "$padded" ]]; then
            mv "$dir" "$parent/$padded"
            echo "Renamed folder: $dir -> $parent/$padded"
        fi
        return
    fi

    # two-part numbers: 145--3 -> 00145--003
    if [[ "$base" =~ ^([0-9]+)--([0-9]+)$ ]]; then
        num1=$(pad_number "${BASH_REMATCH[1]}")
        num2=$(printf "%03d" "$((10#${BASH_REMATCH[2]}))")

        padded="${num1}--${num2}"

        if [[ "$base" != "$padded" ]]; then
            mv "$dir" "$parent/$padded"
            echo "Renamed folder: $dir -> $parent/$padded"
        fi
        return
    fi

    # prefix + number + text + number
    if [[ "$base" =~ ^(.*?)([0-9]+)([^0-9]+)([0-9]+)$ ]]; then
        prefix="${BASH_REMATCH[1]}"
        num1="${BASH_REMATCH[2]}"
        middle="${BASH_REMATCH[3]}"
        num2="${BASH_REMATCH[4]}"

        padded="${prefix}$(pad_number "$num1")${middle}$(printf "%03d" "$((10#$num2))")"

        if [[ "$base" != "$padded" ]]; then
            mv "$dir" "$parent/$padded"
            echo "Renamed folder: $dir -> $parent/$padded"
        fi
        return
    fi

    # prefix + number
    if [[ "$base" =~ ^(.*[^0-9])([0-9]+)$ ]]; then
        prefix="${BASH_REMATCH[1]}"
        num="${BASH_REMATCH[2]}"

        padded="${prefix}$(pad_number "$num")"

        if [[ "$base" != "$padded" ]]; then
            mv "$dir" "$parent/$padded"
            echo "Renamed folder: $dir -> $parent/$padded"
        fi
    fi
}

while read -r dir; do
    rename_folder "$dir"
done < <(get_lowest_dirs)

echo "Rename Folders Process finished successfully."
exit 0