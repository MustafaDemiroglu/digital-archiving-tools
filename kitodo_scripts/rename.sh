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

TARGET_DIR="${kitodo_metadata_path}/${kitodo_processid}"
RENAME_FILE="${TARGET_DIR}/rename.txt"
FIRST_LINE=""

# 1-Only run for renamed processtitle as Rename_
if [[ ! "${kitodo_processtitle}" =~ ^Rename_ ]]; then
    log_info "Process title does not start with 'Rename_'. Nothing to do. Just delete rename.txt"
	if [[ -f "${RENAME_FILE}" ]]; then
        rm -f "${RENAME_FILE}"
        log_info "rename.txt removed. Because no rename needed"
    fi
    exit 0
fi

log_info "Processing Unbekannt workflow: ${kitodo_processtitle}"

# 2- Read metadata to find ArcinsysID
META_FILE="${kitodo_metadata_path}/${kitodo_processid}/meta.xml"

if [[ ! -f "${META_FILE}" ]]; then
    log_error "meta.xml not found: ${META_FILE}"
    exit 5
fi

# read arcinsysid
ARCINSYS_ID=$(xmlstarlet sel -N kitodo="http://meta.kitodo.org/v1/" -t -v \
"//kitodo:metadata[@name='ArcinsysID']" \
"${META_FILE}" 2>/dev/null || true)

if [[ ! -f "${RENAME_FILE}" ]] && [[ -n "${ARCINSYS_ID:-}" && "${ARCINSYS_ID}" =~ ^v[0-9]+$ ]]; then
    log_info "No rename.txt present and Arcinsys ID already assigned. Rename step skipped."
    exit 0
fi

# 3-Extract OLD and NEW full signature path and split path
# Determine OLD_FULL_SIG
if [[ -f "${RENAME_FILE}" ]]; then
    FIRST_LINE=$(head -n1 "${RENAME_FILE}")
	OLD_FULL_SIG="${FIRST_LINE#Unbekannt_}"
	OLD_FULL_SIG="${OLD_FULL_SIG#Rename_}"
    log_info "Old signature determined from rename.txt: ${OLD_FULL_SIG}"
else
    OLD_FULL_SIG="${full_sig_path}"
    log_info "Old signature determined from metadata: ${OLD_FULL_SIG}"
fi

# Determine NEW_FULL_SIG
if [[ -n "${ARCINSYS_ID}" && "${ARCINSYS_ID}" =~ ^v[0-9]+$ ]]; then
    NEW_FULL_SIG="${full_sig_path}"
	log_info "New signature determined from metadata (Arcinsys ID present): ${NEW_FULL_SIG}"
else
    NEW_FULL_SIG="${kitodo_processtitle#Rename_}"
	log_info "New signature determined from processtitle: ${NEW_FULL_SIG}"
fi

# Validation
if [[ -z "${OLD_FULL_SIG}" ]]; then
    log_error "OLD_FULL_SIG empty. Aborting"
    exit 1
fi

if [[ -z "${NEW_FULL_SIG}" ]]; then
    log_error "NEW_FULL_SIG empty. Aborting"
    exit 1
fi

# if nothing changed
if [[ "${OLD_FULL_SIG}" == "${NEW_FULL_SIG}" ]]; then
    log_info "No signature name change detected."
    if [[ -f "${RENAME_FILE}" ]]; then
        rm -f "${RENAME_FILE}"
        log_info "rename.txt removed. Because no rename needed"
    fi
    exit 0
fi

# Split paths
OLD_HAUS=$(echo "${OLD_FULL_SIG}" | cut -d'/' -f1)
OLD_BESTAND=$(echo "${OLD_FULL_SIG}" | cut -d'/' -f2)
OLD_SIG=$(echo "${OLD_FULL_SIG}" | cut -d'/' -f3)

NEW_HAUS=$(echo "${NEW_FULL_SIG}" | cut -d'/' -f1)
NEW_BESTAND=$(echo "${NEW_FULL_SIG}" | cut -d'/' -f2)
NEW_SIG=$(echo "${NEW_FULL_SIG}" | cut -d'/' -f3)

OLD_PREFIX="${OLD_HAUS}/${OLD_BESTAND}/${OLD_SIG}"
NEW_PREFIX="${NEW_HAUS}/${NEW_BESTAND}/${NEW_SIG}"
OLD_FILE_PREFIX="${OLD_HAUS}_${OLD_BESTAND}_nr_${OLD_SIG}_"
NEW_FILE_PREFIX="${NEW_HAUS}_${NEW_BESTAND}_nr_${NEW_SIG}_"

# 3-Locate current and target folder
if [[ ! -f "${md5_file}" ]]; then
    log_error "MD5 file not found: ${md5_file}"
    exit 2
fi

# Use real detected folder from search_folder_vze()
folder_path_refind=$(find "${full_hdd_folder_path}" -path "*/${OLD_FULL_SIG}")

CURRENT_FOLDER="${folder_path_refind}"
PARENT_DIR="$(dirname "${CURRENT_FOLDER}")"

if [[ ! -d "${CURRENT_FOLDER}" ]]; then
    log_error "Current folder not found: ${CURRENT_FOLDER}"
    exit 3
fi

# Determine parent directory dynamically (secure / fremdarchivalien safe)
BASE_PREFIX="${CURRENT_FOLDER%/${OLD_HAUS}/${OLD_BESTAND}/${OLD_SIG}}"

if [[ -z "${BASE_PREFIX}" ]]; then
    log_error "Failed to determine ingest base path."
    exit 1
fi

TARGET_HAUS_DIR="${BASE_PREFIX}/${NEW_HAUS}"
TARGET_BESTAND_DIR="${TARGET_HAUS_DIR}/${NEW_BESTAND}"

log_info "Ensuring target directory structure exists..."

mkdir -p "${TARGET_BESTAND_DIR}"

TARGET_FOLDER="${TARGET_BESTAND_DIR}/${NEW_SIG}"

# 4-Rename folder
if [[ "${CURRENT_FOLDER}" != "${TARGET_FOLDER}" ]]; then
    log_info "Moving folder:"
    log_info "FROM: ${CURRENT_FOLDER}"
    log_info "TO:   ${TARGET_FOLDER}"
	if [[ -e "${TARGET_FOLDER}" ]]; then
		log_error "Target folder already exists: ${TARGET_FOLDER}"
		exit 4
	fi
    mv "${CURRENT_FOLDER}" "${TARGET_FOLDER}"
    CURRENT_FOLDER="${TARGET_FOLDER}"
fi

# 5-Rename contained files (_OLD_ → _NEW_)
log_info "Renaming contained files..."
find "${TARGET_FOLDER}" -type f | while read -r FILE; do
    BASENAME="$(basename "$FILE")"
    DIRNAME="$(dirname "$FILE")"
	if [[ "${BASENAME}" == *"${OLD_FILE_PREFIX}"* ]]; then
        NEW_NAME="${BASENAME//$OLD_FILE_PREFIX/$NEW_FILE_PREFIX}"
        mv "${FILE}" "${DIRNAME}/${NEW_NAME}"
        log_info "Renamed file: ${BASENAME} → ${NEW_NAME}"
    fi
done

# 6-Rename derivate images
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
        if [[ "${BASENAME}" == *"${OLD_FILE_PREFIX}"* ]]; then
			NEW_NAME="${BASENAME//$OLD_FILE_PREFIX/$NEW_FILE_PREFIX}"
			# collision protection
            if [[ -e "${DIRNAME}/${NEW_NAME}" ]]; then
                log_warn "Target image file already exists, skipping: ${NEW_NAME}"
                continue
            fi
			mv "${FILE}" "${DIRNAME}/${NEW_NAME}"
			log_info "Renamed derivate file: ${BASENAME} → ${NEW_NAME}"
		fi
    done
done

# 7-Update MD5 file (locked)
log_info "Updating MD5 file..."
(
    flock --exclusive --timeout 300 200 || exit 1
    sed -i \
        -e "s|${OLD_PREFIX}/${OLD_FILE_PREFIX}|${NEW_PREFIX}/${NEW_FILE_PREFIX}|g" \
        "${md5_file}"

) 200>"${md5_file}.lock"
log_info "MD5 file updated."

# 8-Update meta.xml (remove Unbekannt_ prefix)
if [[ -n "${ARCINSYS_ID}" && "${ARCINSYS_ID}" =~ ^v[0-9]+$ ]]; then
        log_warn "Metadata likely already updated via Arcinsys ID."
		log_warn "Schutzfrist may be checked manually."
else
    log_info "No arcinsysid found. Using default metadata update."
	# Update unitIDCUSTOM and document_type
    xmlstarlet ed -L \
		-N kitodo="http://meta.kitodo.org/v1/" \
		-u "//kitodo:metadata[@name='unitIDCUSTOM']/text()" -v "${NEW_FULL_SIG}" \
		"${META_FILE}"
fi
log_info "meta.xml update completed."

# 9- Write rename summary
log_info "Writing rename summary..."
{
echo "OLD_PROCESS_TITLE: ${FIRST_LINE}"
echo "NEW_PROCESS_TITLE: ${kitodo_processtitle}"
echo "OLD_FULL_SIG: ${OLD_FULL_SIG}"
echo "NEW_FULL_SIG: ${NEW_FULL_SIG}"
} > "${RENAME_FILE}"

#10- exit
log_info "Rename workflow completed successfully."
exit 0