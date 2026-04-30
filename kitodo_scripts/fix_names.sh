#!/bin/bash
# (processid) (processtitle) ${meta.unitIDCUSTOM} ${meta.archiveNameCUSTOM} ${meta.stockUnitIDCUSTOM} ${meta.accessrestrict}
# sourcing library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

# search for current folder of vze and filling variables
search_folder_vze

# HLA Richtlinie = [a-z0-9._-]
VALID_REGEX='^[a-z0-9._-]+$'

# Normalize Names
hla_normalize_name() {
    local name="$1"
    local result="${name}"

    # 1.
    result="${result//Ä/ae}"
    result="${result//ä/ae}"
    result="${result//Ö/oe}"
    result="${result//ö/oe}"
    result="${result//Ü/ue}"
    result="${result//ü/ue}"
    result="${result//ß/ss}"

    # 2. 
    result="${result,,}"

    # 3. / → --
    result="${result////--}"

    # 4. Tab → _
    result="${result// /_}"

    # 5. + → ..
    result="${result//+/..}"

    # 6. sed all again
    #    (all which are not: a-z 0-9 . - _)
    result=$(echo "${result}" | sed 's/[^a-z0-9._-]/_/g')

    echo "${result}"
}

# Check an rename all invalid filenames

rename_count=0
rename_error_count=0

check_and_rename_files() {
    local base_path="$1"

    echo "Checking file names under: ${base_path}"

    while IFS= read -r -d '' filepath; do
        local dir
        local basename
        dir=$(dirname "${filepath}")
        basename=$(basename "${filepath}")

        # Check if filename valid
        if [[ ! "${basename}" =~ ${VALID_REGEX} ]]; then
            local new_name
            new_name=$(hla_normalize_name "${basename}")
            local new_path="${dir}/${new_name}"

            if [[ "${new_name}" == "${basename}" ]]; then
                # if it does not work right
                echo "  [WARN] Cannot auto-fix filename: ${filepath}"
                ((rename_error_count++))
                continue
            fi

            # Targetfile exists already
            if [[ -e "${new_path}" ]]; then
                echo "  [ERROR] Rename target already exists: ${new_path}"
                echo "          Source: ${filepath}"
                ((rename_error_count++))
                continue
            fi

            if mv "${filepath}" "${new_path}"; then
                echo "  [RENAMED] ${filepath}"
                echo "         →  ${new_path}"
                ((rename_count++))
            else
                echo "  [ERROR] Could not rename: ${filepath}"
                ((rename_error_count++))
            fi
        fi
    done < <(find "${base_path}" -type f -print0 | sort -z)

    echo "File rename done: ${rename_count} renamed, ${rename_error_count} errors."
}

# Check Ordnernamen. If invalid then log and exit
folder_error_count=0

check_folder_names() {
    local base_path="$1"

    echo "Checking folder names under: ${base_path}"

    while IFS= read -r -d '' dirpath; do
        local dirname
        dirname=$(basename "${dirpath}")

        if [[ ! "${dirname}" =~ ${VALID_REGEX} ]]; then
            local suggested
            suggested=$(hla_normalize_name "${dirname}")

            echo "  [FOLDER ERROR] Invalid folder name detected!"
            echo "                 Path     : ${dirpath}"
            echo "                 Current  : ${dirname}"
            echo "                 Suggested: ${suggested}"
            echo "                 → Manual correction required."
            ((folder_error_count++))
        fi
    done < <(find "${base_path}" -mindepth 1 -type d -print0 | sort -z)

    echo "Folder check done: ${folder_error_count} folder(s) with invalid names."
}

# Main

# Verify the path exists before doing anything
if [[ ! -d "${folder_path}" ]]; then
    echo "ERROR: HDD ingest path does not exist: ${folder_path}"
    exit 1
fi

# Step 1: Check folder names first — exit early if any are invalid
check_folder_names "${folder_path}"

if [[ ${folder_error_count} -gt 0 ]]; then
    echo ""
    echo "  ABORTED: ${folder_error_count} folder name(s) violate HLA Richtlinie."
    echo "  Manual correction is required before processing can continue."
    exit 2
fi

# Step 2: Auto-fix file names
check_and_rename_files "${folder_path}"

if [[ ${rename_error_count} -gt 0 ]]; then
    echo ""
    echo "  WARNING: ${rename_error_count} file(s) could not be auto-renamed."
    echo "  Manual correction may be required."
    exit 3
fi

echo "End of script ${script_name}"
exit 0