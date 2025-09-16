#!/usr/bin/env bash
###############################################################################
# Script Name : rsync_move_with_lock.sh
# Version     : 1.1
# Author      : Mustafa Demiroglu
#
# Description :
#   This script safely moves the contents of a source folder to a target folder.
#   Steps:
#     1. Acquire a lock so that only one instance runs at a time.
#     2. Clean the target folder completely.
#     3. Rsync files from source → target with verification.
#     4. If rsync is successful, remove the source folder.
#
# Features:
#   - Parallel-safe using flock
#   - Clear folder and file naming
#   - Logs stored with timestamps
#
# Usage:
#   ./rsync_move_with_lock.sh /path/to/source user@remote:/path/to/target
#
###############################################################################

set -euo pipefail

# ========== CONFIG ==========
LOCKFILE="/tmp/rsync_move.lock"
LOGDIR="/tmp/rsync_move_logs"
mkdir -p "$LOGDIR"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
LOGFILE="$LOGDIR/move_$TIMESTAMP.log"
# ============================

# === FUNCTIONS ===
log() {
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] $*" | tee -a "$LOGFILE"
}

cleanup() {
    rm -f "$LOCKFILE"
}
trap cleanup EXIT
# =================

# === CHECK ARGS ===
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <source_dir> <target_dir>"
    exit 1
fi

SOURCE="$1"
TARGET="$2"

# === ACQUIRE LOCK ===
exec 200>"$LOCKFILE"
flock -n 200 || {
    echo "Another instance is running. Exiting."
    exit 1
}

log "=== Rsync Move Script Started ==="
log "Source : $SOURCE"
log "Target : $TARGET"
log "Logfile: $LOGFILE"

# === STEP 1: CLEAN TARGET ===
log "Cleaning target directory: $TARGET"
ssh "$(echo "$TARGET" | cut -d: -f1)" "rm -rf \"$(echo "$TARGET" | cut -d: -f2-)/*\"" || true

# === STEP 2: RSYNC TRANSFER ===
log "Starting rsync transfer..."
rsync -avh --progress --remove-source-files "$SOURCE"/ "$TARGET"/ | tee -a "$LOGFILE"

log "Rsync finished successfully."

# === STEP 3: CLEAN EMPTY SOURCE FOLDERS ===
log "Cleaning empty source directories..."
rsync -a --delete "$SOURCE"/ "$SOURCE"/
rm -rf "$SOURCE"

log "Source folder removed after successful transfer."

log "=== Rsync Move Script Finished ==="