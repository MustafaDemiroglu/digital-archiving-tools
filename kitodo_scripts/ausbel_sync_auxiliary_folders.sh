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

# Target path
target_root="${base_path_ceph}/derivate_on_demand/07_${archive}_${stock}/${archive}/${stock}"

# Create target root if missing
mkdir -p "$target_root"

# Ensure permissions
chgrp -R hladigi "$target_root" 2>/dev/null || true
chmod -R 775 "$target_root" 2>/dev/null || true

# Folders that may contain PDFs oder jpegs not processed by generate_derivate.py
special_folders=(
    "findbuch"
    "bestandsblatt"
    "repertorien"
    "konkordanzen"
)

echo "Starting synchronization of PDF folders..."
echo "Archive: ${archive}"
echo "Stock: ${stock}"
echo "Target: ${target_root}"

for folder in "${special_folders[@]}"; do

    echo "Processing folder: ${folder}"

    candidate_paths=(
        "${base_path_ceph}/${archive}/${stock}/${folder}"
        "${base_path_ceph}/secure/${archive}/${stock}/${folder}"
        "${base_path_ceph}/fremdarchivalien/${archive}/${stock}/${folder}"
    )

    found_source=false

    # Special handling for bestandsblatt
    if [[ "$folder" == "bestandsblatt" ]]; then
        ingest_path="/media/cepheus/ingest/testcharts_bestandsblatt/bestandsblatt"
        ingest_files=$(find "$ingest_path" \
            -type f \
            -name "*${archive}_${stock}*" 2>/dev/null)
        target_path="${target_root}/${folder}"

        # First check normal sources
        for source_path in "${candidate_paths[@]}"; do
            if [[ -d "$source_path" ]]; then
                found_source=true
                mkdir -p "$target_path"
                echo "Synchronizing bestandsblatt:"
                echo " Source: ${source_path}"
                echo " Target: ${target_path}"
                rsync -av \
                    --ignore-existing \
                    "${source_path}/" \
                    "${target_path}/"
            fi
        done

        # If no normal bestandsblatt exists
        if [[ "$found_source" == false ]]; then
            if [[ -n "$ingest_files" ]]; then
                mkdir -p "$target_path"
                # Target empty -> copy from ingest
                if [[ -z "$(ls -A "$target_path")" ]]; then
                    echo "No bestandsblatt found in archive."
                    echo "Copying from ingest source."
                    rsync -av \
                        $(dirname "$ingest_files")/ \
                        "$target_path/"
                else
                    echo "Checking ingest bestandsblatt against existing target..."
                    for file in $ingest_files; do
                        filename=$(basename "$file")
                        if [[ -f "${target_path}/${filename}" ]]; then
                            if ! cmp -s \
                                "$file" \
                                "${target_path}/${filename}"; then
                                echo "ERROR:"
                                echo "Different bestandsblatt detected:"
                                echo "Source: $file"
                                echo "Target: ${target_path}/${filename}"
                                exit 1
                            fi
                        fi
                    done
                    echo "Bestandsblatt validation successful."
                fi
            else
                echo "WARN: No bestandsblatt source found."
            fi
        fi
        continue
    fi
	
    for source_path in "${candidate_paths[@]}"; do
        if [[ -d "$source_path" ]]; then
            found_source=true
			target_path="${target_root}/${folder}"
			mkdir -p "$target_path"
			chgrp -R hladigi "$target_path" 2>/dev/null || true
			chmod -R 775 "$target_path" 2>/dev/null || true
            echo "Synchronizing:"
            echo "  Source: ${source_path}"
            echo "  Target: ${target_path}"
            rsync -av \
                --ignore-existing \
                "${source_path}/" \
                "${target_path}/"
        fi
    done

    if [[ "$found_source" == false ]]; then
        echo "WARN: No source folder found for ${folder}"
    fi
done

# Final permission correction
chgrp -R hladigi "$target_root" 2>/dev/null || true
chmod -R 775 "$target_root" 2>/dev/null || true

echo "Synchronization finished successfully."

exit 0