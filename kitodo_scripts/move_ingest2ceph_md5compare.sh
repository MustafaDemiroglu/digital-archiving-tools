########### should be rewritten 



#!/bin/bash

# sourcing library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

# search for current folder of vze and filling variables (folder_path, full_hdd_folders, hdd_root_folder, and hdd_sub_folder)
search_folder_vze

# check if checksum file was already successfully moved
# disable shellcheck variable exported in library
# shellcheck disable=SC2154
if [[ -f "${base_path_hdd_ingest_ceph}/${hdd_root_folder}/.checksum_file_successfully_uploaded" ]]; then
    echo "Checksum file was already uploaded, nothing to do."
    exit 0
fi

# Check if MD5 file exists
# shellcheck disable=SC2154
md5_file="${base_path_hdd_ingest_ceph}/${hdd_root_folder}/${meta_delivery}.md5"
if [[ ! -f "${md5_file}" ]]; then
    echo "MD5 file not found under ${md5_file}, skipping MD5 file modification."
    md5_file=""
fi

# Function: trim path
trim() {
  echo -n "$1" | sed 's#^\./##'
}

# Function: compare MD5 of two files
same_file_md5() {
  local f1="$1"
  local f2="$2"
  [[ ! -f "$f1" || ! -f "$f2" ]] && return 1
  local h1=$(md5sum "$f1" | awk '{print $1}')
  local h2=$(md5sum "$f2" | awk '{print $1}')
  [[ "$h1" == "$h2" ]]
}

# Main logic for processing
final_ceph_path="${base_path_ceph}/${hdd_sub_folder}/${full_sig_path}"
final_hdd_path="${base_path_hdd_ingest_ceph}/${hdd_root_folder}/${hdd_sub_folder}/${full_sig_path}"

# Check if final destination folder exists in Ceph
if [[ -d "${final_ceph_path}" ]]; then
    echo "Destination folder already exists! Processing MD5 comparison and file removal..."

    # Get list of files in HDD and Ceph for comparison
    final_hdd_path_filelist=$(find "${final_hdd_path}" -mindepth 1 | sort)
    final_ceph_path_filelist=$(find "${final_ceph_path}" -mindepth 1 | sort)

    # Compare file lists
    final_hdd_path_filelist_length=$(echo "${final_hdd_path_filelist}" | wc -l)
    final_ceph_path_filelist_length=$(echo "${final_ceph_path_filelist}" | wc -l)

    if [[ "${final_hdd_path_filelist_length}" -ne "${final_ceph_path_filelist_length}" ]]; then
        echo "Different number of files in both folders!"
    else
        echo "Same number of files in both folders: ${final_hdd_path_filelist_length}"
    fi

    # Compare first files in both lists
    if grep "$(echo "${final_hdd_path_filelist}" | head -n 1)" <<< "${final_ceph_path_filelist}"; then
        echo "First file of HDD/ingest filelist was found in Ceph filelist!"
    else
        echo "First file of HDD/ingest filelist was NOT found in Ceph filelist."
    fi

    # Process MD5 comparison and file movement
    echo "Processing MD5 comparison and file movement..."

    if [[ -n "$md5_file" ]]; then
        # Read the MD5 file and process each entry
        while IFS= read -r md5_entry; do
            # Extract the file path from MD5 entry (ignoring the checksum part)
            md5_file_path=$(echo "$md5_entry" | awk '{print $2}')
            
            # Trim relative path from the current directory
            trimmed_file_path=$(trim "$md5_file_path")

            # Check if file exists in the source path
            source_file="${base_path_hdd_ingest_ceph}/${hdd_root_folder}/${trimmed_file_path}"
            destination_file="${final_ceph_path}/${trimmed_file_path}"

            if [[ -f "$source_file" ]]; then
                echo "File exists: $source_file"

                # If the file exists in Ceph, perform MD5 comparison
                if same_file_md5 "$source_file" "$destination_file"; then
                    echo "MD5 matches for file: $source_file"
                    # Move file to temporary directory
                    dest="$TMP_DIR/$trimmed_file_path"
                    mkdir -p "$(dirname "$dest")"
                    mv "$source_file" "$dest"
                    # If MD5 file is available, remove MD5 entry for this file
                    if [[ -n "$md5_file" ]]; then
                        sed -i "/$trimmed_file_path/d" "$md5_file"
                    fi
                else
                    echo "MD5 does not match for file: $source_file"
                fi
            else
                echo "Source file does not exist: $source_file"
            fi
        done < "$md5_file"
    fi
else
    # Create destination directory in Ceph if it doesn't exist
    sg "${group}" -c "mkdir -vp ${final_ceph_path}"
fi

# Move the files to Ceph using rsync, excluding already existing files
echo "Moving remaining files to Ceph..."
if ! rsync -rtv --perms --chmod=D2770,F0660 --chown=:hladigi --ignore-existing --remove-source-files "${final_hdd_path}/" "${final_ceph_path}"; then
    echo "Error while moving files with rsync!"
    exit 1
fi

# Check if the source folder is empty after the transfer
if [[ $(find "${final_hdd_path}/" -type d ! -empty | wc -l) -eq 0 ]]; then
    echo "Source folder is empty: ${final_hdd_path}/"
else
    echo "Source folder is not empty, please check! Aborting."
    exit 4
fi

# Mark the checksum file as successfully uploaded
touch "${base_path_hdd_ingest_ceph}/${hdd_root_folder}/.checksum_file_successfully_uploaded"

# Final message
echo "End of script ${script_name}"