#!/usr/bin/env bash

set -euo pipefail

# Logging (Kitodo Standard)
log_info()  { echo "[INFO]  $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn()  { echo "[WARN]  $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }


# Argument check
if [ "$#" -ne 1 ]; then
    log_error "Usage: $0 /path/to/digitalisat_folder"
    exit 1
fi

WORK_DIR="$1"

if [ ! -d "$WORK_DIR" ]; then
    log_error "Directory does not exist: $WORK_DIR"
    exit 1
fi

META_FILE="$WORK_DIR/meta.xml"

if [ ! -f "$META_FILE" ]; then
    log_error "meta.xml not found in $WORK_DIR"
    exit 1
fi

log_info "Starting rename process for $WORK_DIR"

# Read new signature from meta.xml
NEW_UNIT=$(xmllint --xpath \
"string(//metadata[@name='unitIDCUSTOM'])" \
"$META_FILE" 2>/dev/null || true)

if [ -z "$NEW_UNIT" ]; then
    log_error "unitIDCUSTOM not found or empty in meta.xml"
    exit 1
fi

# hstam/0test/4 → only last segment
NEW_SIG="${NEW_UNIT##*/}"

# Determine old signature from folder name
OLD_SIG=$(basename "$WORK_DIR")
PARENT_DIR=$(dirname "$WORK_DIR")

log_info "Old signature (folder name): $OLD_SIG"
log_info "New signature (metadata):    $NEW_SIG"

# Compare and act
# If no change → exit clean
if [ "$OLD_SIG" = "$NEW_SIG" ]; then
    log_info "No rename necessary. Signatures match."
    exit 0
fi

TARGET_DIR="$PARENT_DIR/$NEW_SIG"

if [ -e "$TARGET_DIR" ]; then
    log_error "Target directory already exists: $TARGET_DIR"
    exit 1
fi


# Rename folder
log_info "Renaming folder..."
mv "$WORK_DIR" "$TARGET_DIR"
log_info "Folder renamed to $TARGET_DIR"


# Rename contained files (prefix replacement)
log_info "Renaming contained files..."

for FILE in "$TARGET_DIR"/*; do
    [ -f "$FILE" ] || continue

    BASENAME=$(basename "$FILE")

	# match only _OLD_SIG_
    if [[ "$BASENAME" =~ _${OLD_SIG}_ ]]; then
        NEW_NAME="$(echo "$BASENAME" | sed "s/_${OLD_SIG}_/_${NEW_SIG}_/g")"
        mv "$FILE" "$TARGET_DIR/$NEW_NAME"
        log_info "Renamed file: $BASENAME → $NEW_NAME"
    fi
done

# Update MD5 file
log_info "Updating MD5 file..."

MD5_FILE=$(find "$PARENT_DIR" -maxdepth 1 -name "*.md5" | head -n 1 || true)

if [ -n "$MD5_FILE" ]; then
    # replace /OLD_SIG/ only as path segment
    sed -i \
        -e "s|/${OLD_SIG}/|/${NEW_SIG}/|g" \
        -e "s|_${OLD_SIG}_|_${NEW_SIG}_|g" \
        "$MD5_FILE"

    log_info "MD5 updated: $(basename "$MD5_FILE")"
else
    log_warn "No MD5 file found."
fi

log_info "Rename process completed successfully."
exit 0
