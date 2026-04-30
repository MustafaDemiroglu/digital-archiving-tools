#!/bin/bash
# (processid) (processtitle) ${meta.unitIDCUSTOM} ${meta.archiveNameCUSTOM} ${meta.stockUnitIDCUSTOM} ${meta.accessrestrict}
# sourcing library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

# search for current folder of vze and filling variables (folder_path, full_hdd_folders, hdd_root_folder, and hdd_sub_folder)
search_folder_vze

# check if checksum file was already successfully moved
if [[ -f "${base_path_hdd_ingest_ceph}/${hdd_root_folder}/.checksum_file_successfully_uploaded" ]]; then
    echo "Checksum file was already uploaded, nothing to do. Do it manually"
    exit 0
fi

# Check if MD5 file exists
md5_file="${base_path_hdd_ingest_ceph}/${hdd_root_folder}/${meta_delivery}.md5"
if [[ ! -f "${md5_file}" ]]; then
    echo "MD5 file not found under ${md5_file}, skipping MD5 file modification."
    md5_file=""
fi

# Shared deleted_duplikaten.md5 — same directory as the lieferung MD5 file.
deleted_md5_file="${base_path_hdd_ingest_ceph}/${hdd_root_folder}/deleted_duplikaten.md5"
deleted_md5_lockfile="${deleted_md5_file}.lock"

# get MD5 hash of a single file
get_md5() {
    local f="$1"
    [[ ! -f "$f" ]] && return 1
    md5sum "$f" | awk '{print $1}'
}

# append one "hash  path" line to deleted_duplikaten.md5, uses flock so can kitodo also parallel
append_to_deleted_md5() {
    local hash="$1"
    local filepath="$2"
    (
        flock -x 200
        echo "${hash}  ${filepath}" >> "${deleted_md5_file}"
    ) 200>"${deleted_md5_lockfile}"
}

# remove a path entry from the lieferung MD5 file (md5_file). use flock
remove_from_lieferung_md5() {
    local trimmed_path="$1"
    [[ -z "${md5_file}" || ! -f "${md5_file}" ]] && return 0
    local lockfile="${md5_file}.lock"
    (
        flock -x 201
        # escape possible regex special chars in path before passing to sed
        local escaped
        escaped=$(printf '%s\n' "${trimmed_path}" | sed 's/[[\.*^$()+?{|]/\\&/g')
        sed -i "/${escaped}/d" "${md5_file}"
    ) 201>"${lockfile}"
}

# Populates the global associative array  ceph_md5_map by scanning both possible Ceph locations
build_ceph_md5_map() {
    declare -g -A ceph_md5_map   # global so process_duplicate_removal can use it

    local candidates=(
        "${base_path_ceph}/${full_sig_path}"
        "${base_path_ceph}/secure/${full_sig_path}"
    )

    local total=0
    for ceph_candidate in "${candidates[@]}"; do
        if [[ ! -d "${ceph_candidate}" ]]; then
            echo "  [ceph-scan] Path does not exist, skipping: ${ceph_candidate}"
            continue
        fi
        echo "  [ceph-scan] Indexing: ${ceph_candidate}"
        while IFS= read -r -d '' ceph_file; do
            local md5
            md5=$(get_md5 "${ceph_file}") || continue
            # If the same hash appears in both locations, the last one wins —
            # for duplicate-detection purposes this is fine.
            ceph_md5_map["${md5}"]="${ceph_file}"
            ((total++))
        done < <(find "${ceph_candidate}" -type f -print0)
    done

    echo "  [ceph-scan] Total files indexed from Ceph: ${total}"
}

#   Compares every file. Identical files deleted, removed from the lieferung MD5 list, and recorded in deleted_duplikaten.md5.
process_duplicate_removal() {
    echo "Duplicate check: comparing HDD ingest vs Ceph(secure + non-secure) by MD5"

    build_ceph_md5_map

	if [[ ${#ceph_md5_map[@]} -eq 0 ]]; then
        echo "Ceph index is empty — no duplicates can be detected. Skipping."
        return 0
    fi
	
    local moved_count=0
    local skipped_count=0

    # Walk every file in the HDD ingest source
    while IFS= read -r -d '' hdd_file; do
        local md5
        md5=$(get_md5 "${hdd_file}") || { echo "Cannot hash: ${hdd_file}"; continue; }

        if [[ -n "${ceph_md5_map[${md5}]}" ]]; then
            # Duplicate found 
            echo "  [DUP] ${hdd_file}  (MD5: ${md5})"

			# 1. Append to deleted_duplikaten.md5 BEFORE deleting files
            append_to_deleted_md5 "${md5}" "${hdd_file}"
			
			# 2. Remove from lieferung MD5 file
            local relative_path="${hdd_file#${base_path_hdd_ingest_ceph}/${hdd_root_folder}/}"
            remove_from_lieferung_md5 "${relative_path}"
			
			# 3. Delete the file from HDD ingest
            if rm -f "${hdd_file}"; then
                echo "         ↳ deleted from HDD ingest."
                ((moved_count++))
            else
                echo "  [ERROR] Could not delete: ${hdd_file}"
            fi
        else
            ((skipped_count++))
        fi
    done < <(find "${folder_path}" -type f -print0)

	# Remove empty directories left behind under folder_path
    find "${folder_path}" -mindepth 1 -depth -type d -empty -exec rmdir -v {} \;
    echo "Duplicate removal done: ${moved_count} deleted, ${skipped_count} unique (kept)."
}

# Main logic for processing
if [ "${vze_accessrestrict}" == "true" ]; then
    #move all secure file to secure structure in ceph
    final_ceph_path="${base_path_ceph}/secure/${full_sig_path}"
else
    final_ceph_path="${base_path_ceph}/${full_sig_path}"
fi

# Check if final destination folder exists in Ceph
if [[ -d "${final_ceph_path}" ]]; then
    echo "Destination folder already exists! Processing MD5 comparison and file removal..."

    # MD5-based duplicate removal
	process_duplicate_removal
	
else
    # Create destination directory in Ceph if it doesn't exist
	echo "Destination folder does not exists! Nothing to do"
fi

# Final check — folder must still exist for downstream scripts to continue
if [[ ! -d "${folder_path}" ]]; then
    echo "ERROR: Signature folder does not exist after duplicate removal: ${folder_path}"
    echo "Aborting — downstream processing requires this folder."
	echo "You can delete this ${kitodo_processid} from Kitodo."
    exit 4
fi

# Final message
echo "End of script ${script_name}"
exit 0