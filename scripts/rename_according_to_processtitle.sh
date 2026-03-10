#!/bin/bash
# see library for needed parameters

set -euo pipefail

# Source Kitodo library
if ! source "$(dirname "${0}")"/lib_hla_kitodo.sh; then
    echo "Failed to include library file! please check."
    exit 5
fi

search_folder_vze

# Logging , can be deleted if no needed
log_info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

# 1-Only run for renamed processtitle as Umbenennen_
if [[ ! "${kitodo_processtitle}" =~ ^Umbenennen_ ]]; then
    log_info "Process title does not start with 'Umbenennen_'. Nothing to do."
    exit 0
fi

log_info "Processing Unbekannt workflow: ${kitodo_processtitle}"

# 2-Extract OLD and NEW full signature path
OLD_FULL_SIG="${meta_unitIDCUSTOM}"
NEW_FULL_SIG="${kitodo_processtitle#Umbenennen_}"

if [[ -z "${OLD_FULL_SIG}" ]]; then
    log_error "meta_unitIDCUSTOM is empty. Aborting."
    exit 1
fi

log_info "Old full signature: ${OLD_FULL_SIG}"
log_info "New full signature: ${NEW_FULL_SIG}"

if [[ "${OLD_FULL_SIG}" == "${NEW_FULL_SIG}" ]]; then
    log_info "No signature name change detected. Nothing to do."
    exit 0
fi

OLD_SIG="${OLD_FULL_SIG##*/}"
NEW_SIG="${NEW_FULL_SIG##*/}"

log_info "Old leaf signature: ${OLD_SIG}"
log_info "New leaf signature: ${NEW_SIG}"

# 3-Locate current folder via delivery md5
md5_file="${base_path_hdd_ingest_ceph}/${hdd_root_folder}/${meta_delivery}.md5"

if [[ ! -f "${md5_file}" ]]; then
    log_error "MD5 file not found: ${md5_file}"
    exit 2
fi

# Use real detected folder from search_folder_vze()
CURRENT_FOLDER="${folder_path}"

# Determine parent directory dynamically (secure / fremdarchivalien safe)
PARENT_DIR="$(dirname "${CURRENT_FOLDER}")"
TARGET_FOLDER="${PARENT_DIR}/${NEW_SIG}"

if [[ ! -d "${CURRENT_FOLDER}" ]]; then
    log_error "Current folder not found: ${CURRENT_FOLDER}"
    exit 3
fi

if [[ -e "${TARGET_FOLDER}" ]]; then
    log_error "Target folder already exists: ${TARGET_FOLDER}"
    exit 4
fi

# 4-Rename folder
log_info "Renaming folder..."
mv "${CURRENT_FOLDER}" "${TARGET_FOLDER}"
log_info "Folder renamed."

# 5-Rename contained files (_OLD_ → _NEW_)
log_info "Renaming contained files..."

find "${TARGET_FOLDER}" -type f | while read -r FILE; do
    BASENAME="$(basename "$FILE")"
    DIRNAME="$(dirname "$FILE")"

    if [[ "${BASENAME}" == *"_${OLD_SIG}_"* ]]; then
        NEW_NAME="${BASENAME//_${OLD_SIG}_/_${NEW_SIG}_}"
        mv "${FILE}" "${DIRNAME}/${NEW_NAME}"
        log_info "Renamed file: ${BASENAME} → ${NEW_NAME}"
    fi
done

# 6-Rename derivate images (_OLD_ → _NEW_)
log_info "Renaming derivative images (max/thumbs/tiff)..."

final_kitodo_image_path="${kitodo_metadata_path}/${kitodo_processid}/images"

for SUBDIR in "max" "thumbs" "tiff"; do

    IMG_PATH="${final_kitodo_image_path}/${SUBDIR}"

    if [[ ! -d "${IMG_PATH}" ]]; then
        log_warn "Image folder not found, skipping: ${IMG_PATH}"
        continue
    fi

    log_info "Processing image folder: ${IMG_PATH}"

    find "${IMG_PATH}" -type f | while read -r FILE; do
        BASENAME="$(basename "$FILE")"
        DIRNAME="$(dirname "$FILE")"

        if [[ "${BASENAME}" == *"_${OLD_SIG}_"* ]]; then
            NEW_NAME="${BASENAME//_${OLD_SIG}_/_${NEW_SIG}_}"

            # collision protection
            if [[ -e "${DIRNAME}/${NEW_NAME}" ]]; then
                log_warn "Target image file already exists, skipping: ${NEW_NAME}"
                continue
            fi

            mv "${FILE}" "${DIRNAME}/${NEW_NAME}"
            log_info "Renamed image: ${BASENAME} → ${NEW_NAME}"
        fi
    done

done

# 7-Update MD5 file (locked)
log_info "Updating MD5 file..."

(
    flock --exclusive --timeout 300 200 || exit 1

    sed -i \
        -e "s|/${OLD_SIG}/|/${NEW_SIG}/|g" \
        -e "s|_${OLD_SIG}_|_${NEW_SIG}_|g" \
        "${md5_file}"

) 200>"${md5_file}.lock"

log_info "MD5 file updated."

# 7-Update meta.xml (remove Unbekannt_ prefix)
META_FILE="${kitodo_metadata_path}/${kitodo_processid}/meta.xml"

if [[ ! -f "${META_FILE}" ]]; then
    log_error "meta.xml not found: ${META_FILE}"
    exit 5
fi

# read arcinsysid
ARCINSYS_ID=$(xmlstarlet sel -N kitodo="http://meta.kitodo.org/v1/" -t -v \
"//kitodo:metadata[@name='ArcinsysID']" \
"${META_FILE}" 2>/dev/null || true)

if [[ -n "${ARCINSYS_ID}" && "${ARCINSYS_ID}" =~ ^v[0-9]+$ ]]; then
    log_info "arcinsysid detected (${ARCINSYS_ID}). Special handling branch."

    if [[ "${meta_document_type}" == "Unknown" ]]; then
        log_info "Updating title for Unknown process (arcinsys mode)..."

        # update metadata 
		# update metadata for Unknown process
        # Example of how to modify the title based on arcinsysid
        # Additional logic here, if necessary
    fi

else
    log_info "No arcinsysid found. Using default metadata update."

	# Update unitIDCUSTOM and document_type
    xmlstarlet ed -L \
		-N kitodo="http://meta.kitodo.org/v1/" \
		-u "//kitodo:metadata[@name='unitIDCUSTOM']/text()" -v "${NEW_FULL_SIG}" \
		"${META_FILE}"
fi

log_info "meta.xml update completed."

log_info "Rename workflow completed successfully."
exit 0