#!/bin/bash
# sourcing library to read signature values from lib_hla_kitodo. see library for needed parameters
# exported as env over read_parameters_and_export_json_to_env function
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! Please check."
    exit 5
fi

for cmd in rsync md5sum xmlstarlet flock sg mktemp; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "ERROR: '${cmd}' not found."; exit 2; }
done

# Digishare upload directory variable defined
base_path_digishare_upload="/media/cepheus/ingest/digishare_upload"

# Split full signature path
haus=$(echo "${full_sig_path}" | cut -d'/' -f1)
bestand=$(echo "${full_sig_path}" | cut -d'/' -f2)
signatur=$(echo "${full_sig_path}" | cut -d'/' -f3)

# Check signature values
if [[ -z "${haus}" || -z "${bestand}" || -z "${signatur}" ]]; then
    echo "ERROR: Could not read the full signature path."
    echo "Please check the Kitodo metadata."
    exit 1
fi

# Find Digishare source folder
case "${haus}" in
    hstam)
        source_haus_dir="hla_hstam_transfer"
        ;;
    hstad)
        source_haus_dir="darmstadt_hstad_transfer"
        ;;
    adjb)
        source_haus_dir="hla_adjb_transfer"
        ;;
    hhstaw)
        source_haus_dir="hla_hhstaw_transfer"
        ;;
    *)
        echo "ERROR: No Digishare source folder is defined for archive '${haus}'."
        echo "Please check the Digishare folder mapping."
        exit 1
        ;;
esac

# Define source and target paths
source_path="${base_path_digishare_upload}/${source_haus_dir}/${bestand}/${signatur}"
source_bestand_path="${base_path_digishare_upload}/${source_haus_dir}/${bestand}"
# Create upload folder name
now_epoch=$(date +%s)
upload_date=$(date -d "@${now_epoch}" '+%Y-%m-%d')
upload_date_compact=$(date -d "@${now_epoch}" '+%Y%m%d')
upload_folder_path="${upload_date}_${haus}_digishare"
# Final target path
final_target_path="${base_path_hdd_ingest_ceph}/${upload_folder_path}/${full_sig_path}"
# MD5 file name tha will be later used in Kitodo metadata as delivery
md5_datei_name="${haus}_digishare_${upload_date_compact}"
# Real MD5 file including extension to use 
real_md5_datei="${base_path_hdd_ingest_ceph}/${upload_folder_path}/${md5_datei_name}.md5"

# Temporary directory for this process. That will be used to read checksums direct vom rsync
tmp_dir=$(mktemp -d "${kitodo_metadata_path}/${kitodo_processid}/digishare_upload.XXXXXX") || { echo "ERROR: tmp dir could not defined"; exit 1; }
# Clean temporary files when the script ends
cleanup() {
    rm -rf "${tmp_dir}"
}
trap cleanup EXIT
# Temporary files
rsync_output="${tmp_dir}/rsync_output.txt"
md5_entries="${tmp_dir}/md5_entries.txt"

# Show basic information for next moves
echo "INFO: Preparing Digishare files for Kitodo Ingest."
echo "INFO: Archive: ${haus}"
echo "INFO: Bestand: ${bestand}"
echo "INFO: Signatur: ${signatur}"
echo "INFO: Source: ${source_path}"
echo "INFO: Target: ${final_target_path}"

# Check source directory and if contains files
if [[ ! -d "${source_path}" ]]; then
    echo "ERROR: Source folder was not found: ${source_path}"
    echo "Please check if the Digishare files are available."
    exit 1
fi

if ! find "${source_path}" -type f -print -quit | grep -q .; then
    echo "ERROR: Source folder contains no files: ${source_path}"
    echo "Please check if the Digishare transfer is complete."
    exit 1
fi
echo "INFO: Source folder found and contains files."

# Create target directory
if ! sg "${group}" -c "mkdir -vp '${final_target_path}'"; then
    echo "ERROR: Could not create target folder: ${final_target_path}"
    exit 1
fi
echo "INFO: Target folder is ready."

# Move files with rsync
echo "INFO: Moving files to the Kitodo Ingest folder..."
if ! rsync \
    -rtv \
    --perms \
    --chmod=D2770,F0660 \
    --chown=:"${group}" \
    --ignore-existing \
    --remove-source-files \
    --itemize-changes \
    --out-format='%i|%n' \
    "${source_path}/" \
    "${final_target_path}/" \
    > "${rsync_output}"; then
    echo "ERROR: File transfer with rsync failed."
    echo "Please check the source and target folders."
    exit 1
fi

# Read successfully transferred files
transferred_count=0
while IFS='|' read -r itemize_code relative_file; do
    # Skip empty lines
    [[ -z "${itemize_code}" ]] && continue
    [[ -z "${relative_file}" ]] && continue
    # A new file transferred by rsync starts with >f
    if [[ "${itemize_code}" == ">f"* ]]; then
        target_file="${final_target_path}/${relative_file}"
        # Make sure the file really exists at the target
        if [[ ! -f "${target_file}" ]]; then
            echo "ERROR: Transferred file was not found at target: ${target_file}"
            exit 1
        fi
        # Save file for MD5 creation
        echo "${target_file}" >> "${md5_entries}"
        transferred_count=$((transferred_count + 1))
        echo "INFO: File moved: ${relative_file}"
    fi
done < "${rsync_output}"

# Check transfer result
if [[ "${transferred_count}" -eq 0 ]]; then
    echo "ERROR: No new files were moved. Please check the source and target folders."
    exit 1
fi
echo "INFO: ${transferred_count} file(s) moved successfully."

# Remove empty source folders
echo "INFO: Removing empty source folders..."
if ! find "${source_path}" -depth -type d -empty -delete; then
    echo "WARNING: Source Signatur folder could not be removed. Check if it is empty"
else
    echo "INFO: Empty source signatur folder removed."
	# Check and remove bestand folder if it became empty
    if ! find "${source_bestand_path}" -maxdepth 0 -type d -empty -delete; then
        echo "WARNING: Source Bestand folder could not be removed. It is not empty."
    else
		echo "INFO: Empty source bestand folder removed."
	fi
fi

# Check MD5 file self and filename and create if it does not exist
if [[ -z "${md5_datei_name}" ]]; then
    echo "ERROR: MD5 file name is not defined."
    exit 1
fi
if [[ -z "${real_md5_datei}" ]]; then
    echo "ERROR: Real MD5 file path is not defined."
    exit 1
fi
if [[ ! -f "${real_md5_datei}" ]]; then
    echo "INFO: MD5 file does not exist. Creating it."
    if ! sg "${group}" -c "touch '${real_md5_datei}' && chmod 0660 '${real_md5_datei}'"; then
        echo "ERROR: Could not create MD5 file: ${real_md5_datei}"
        exit 1
    fi
    echo "INFO: MD5 file created successfully"
else
    echo "INFO: Existing MD5 file will be kept to avoid overwrite"
fi

# Generate MD5 entries
echo "INFO: Generating MD5 checksums"
md5_count=0
while IFS= read -r target_file; do
    [[ -z "${target_file}" ]] && continue
    if [[ ! -f "${target_file}" ]]; then
        echo "ERROR: File for MD5 was not found: ${target_file}"
        exit 1
    fi
    if ! md5_line=$(md5sum "${target_file}" 2>/dev/null); then
        echo "ERROR: Could not generate MD5: ${target_file}"
        exit 1
    fi
    md5="${md5_line%% *}"
    # Remove /media/cepheus/ from the path
    cleaned_path="${target_file#${base_path_hdd_ingest_ceph}/${upload_folder_path}/}"
    echo "${md5}  ${cleaned_path}" >> "${md5_entries}.ready"
    md5_count=$((md5_count + 1))
done < "${md5_entries}"
if [[ "${md5_count}" -eq 0 ]]; then
    echo "ERROR: No MD5 checksums were generated."
    exit 1
fi
echo "INFO: ${md5_count} MD5 checksum(s) generated."

# Update MD5 file safely
echo "INFO: Updating MD5 file..."
(   # Only one process may update this MD5 file at a time.
    if ! flock --exclusive --timeout 300 200; then
        echo "ERROR: Could not lock MD5 file within 5 minutes."
        exit 1
    fi
    # Append new entries. Existing entries are never removed.
    if ! cat "${md5_entries}.ready" >> "${real_md5_datei}"; then
        echo "ERROR: Could not update MD5 file: ${real_md5_datei}"
        exit 1
    fi
    # Keep the correct group and permissions.
    if ! chgrp "${group}" "${real_md5_datei}"; then
        echo "ERROR: Could not set MD5 file group."
        exit 1
    fi
    if ! chmod 0660 "${real_md5_datei}"; then
        echo "ERROR: Could not set MD5 file permissions."
        exit 1
    fi
) 200>"${real_md5_datei}.lock"
if [[ $? -ne 0 ]]; then
    echo "ERROR: MD5 file update failed."
    exit 1
fi
echo "INFO: MD5 file updated successfully."

# Update Kitodo delivery metadata
META_FILE="${kitodo_metadata_path}/${kitodo_processid}/meta.xml"
if [[ -z "${META_FILE:-}" ]]; then
    echo "ERROR: META_FILE is not defined or not found. Please check the Kitodo library configuration."
    exit 1
fi
echo "INFO: Updating Kitodo delivery metadata..."
# check delivery node in metadata
delivery_exists=$(xmlstarlet sel -N kitodo="http://meta.kitodo.org/v1/" \
    -t -v "count(//kitodo:metadata[@name='delivery'])" \
    "${META_FILE}")
if [[ "${delivery_exists}" -eq 0 ]]; then
    # delivery node not exists. create a new node and attribute (in 2 moves)
    echo "INFO: No existing delivery entry found. Creating a new one."
    if ! xmlstarlet ed -L \
        -N kitodo="http://meta.kitodo.org/v1/" \
        -s "//kitodo:kitodo" -t elem -n "kitodo:metadata" -v "${md5_datei_name}" \
        "${META_FILE}"; then
        echo "ERROR: Could not create delivery metadata node."
        exit 1
    fi
    if ! xmlstarlet ed -L \
        -N kitodo="http://meta.kitodo.org/v1/" \
        -i "(//kitodo:metadata[not(@name)])[last()]" -t attr -n "name" -v "delivery" \
        "${META_FILE}"; then
        echo "ERROR: Could not set 'name' attribute on new delivery metadata node."
        exit 1
    fi
else
    # delivery node exists already ->  just update
    echo "INFO: Existing delivery entry found. Updating it."
    if ! xmlstarlet ed -L \
        -N kitodo="http://meta.kitodo.org/v1/" \
        -u "//kitodo:metadata[@name='delivery']/text()" \
        -v "${md5_datei_name}" \
        "${META_FILE}"; then
        echo "ERROR: Could not update delivery metadata."
        exit 1
    fi
fi
echo "INFO: Delivery metadata updated: ${md5_datei_name}"
    
# Finished
echo "INFO: Transfer from digishare_upload to hdd_upload completed."
echo "INFO: Files moved: ${transferred_count}"
echo "INFO: MD5 entries added: ${md5_count}"
echo "INFO: MD5 file: ${real_md5_datei}"
echo "INFO: Kitodo delivery: ${md5_datei_name}"
echo "INFO: Script finished successfully."

exit 0