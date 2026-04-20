#!/bin/bash

###############################################################################
# Script Name : cleanup_transfer.sh
# Version     : 1.3
# Author      : Mustafa Demiroglu
# Purpose     :
#   After a transfer/Lieferung has been ingested to /media/cepheus,
#   verify each file by MD5 hash and PERMANENTLY DELETE confirmed copies.
#   Then clean up empty folders, metadata files, hidden items, and
#   OS/system junk left on the source drive/folder.
#
# Usage:
#   ./cleanup_transfer.sh <source_folder>
#
#   <source_folder>   : Root of the transfer/Lieferung (e.g. /mnt/transfer)
#
# Safety features:
#   - Dry-run mode by default (set DRY_RUN=0 to actually delete)
#   - Full log written to /media/cepheus/ingest/hdd_upload/cleanup_<timestamp>.log
#   - Summary counters at the end
#   - Never touches /media/cepheus itself
###############################################################################

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-1}"          # 1 = simulate only, 0 = real deletions
CEPHEUS_ROOT="/media/cepheus"
LOG_DIR="/media/cepheus/ingest/hdd_upload"
SOURCE_ROOT="${1:-}"

# Metadata / checksum patterns to remove after MD5 phase
METADATA_PATTERNS=(
    "*.md5"
    "*.csv"
    "rhash.txt"
    "rhash.txt.unix"
    "*.sfv"
    "*.sha1"
    "*.sha256"
)

# ── OS junk: files (matched by name, case-insensitive) ────────────────────────
JUNK_FILES=(
    # Windows
    "Thumbs.db"             # thumbnail cache
    "Thumbs.db:encryptable" # encrypted variant
    "ehthumbs.db"           # media center thumbnails
    "ehthumbs_vista.db"     # vista variant
    "desktop.ini"           # folder config
    "autorun.inf"           # autorun descriptor
    "*.lnk"                 # Windows shortcuts
    "*.url"                 # Internet shortcuts
    "*.tmp"                 # temp files
    "hiberfil.sys"          # hibernation file
    "pagefile.sys"          # page file
    "swapfile.sys"          # swap file

    # macOS
    ".DS_Store"             # folder metadata
    ".AppleDouble"          # resource fork remnant
    ".LSOverride"           # Launch Services override
    ".AppleDB"              # old AppleShare DB
    ".AppleDesktop"         # old AppleShare desktop
    ".VolumeIcon.icns"      # volume icon
    "._*"                   # AppleDouble resource forks

    # Linux / general
    ".directory"            # KDE folder settings
    ".fuse_hidden*"         # FUSE leftover files
    ".nfs*"                 # NFS stale handles
    "*~"                    # editor backup files (vim, gedit, etc.)
    "*.swp"                 # vim swap files
    "*.swo"                 # vim swap files (overflow)
    ".bash_history"
    ".bash_logout"
    ".bash_profile"
    ".zsh_history"
    ".lesshst"
    ".wget-hsts"
)

# ── OS junk: directories (matched by name, case-insensitive) ──────────────────
JUNK_DIRS=(
    # Windows
    "\$RECYCLE.BIN"                 # recycle bin
    "RECYCLER"                      # old recycle bin (XP)
    "\$Recycle.Bin"                 # variant capitalisation
    "System Volume Information"     # VSS / restore points
    "\$WinREAgent"                  # Windows Recovery
    "\$SysReset"                    # Windows reset leftovers
    "\$WINDOWS.~BT"                 # Windows upgrade staging
    "\$WINDOWS.~WS"                 # Windows upgrade staging
    "FOUND.000"                     # chkdsk recovery fragments

    # macOS
    ".Spotlight-V100"               # Spotlight index
    ".Trashes"                      # Trash folder
    ".fseventsd"                    # FSEvents journal
    ".TemporaryItems"               # temporary items
    ".MobileBackups"                # Time Machine mobile backups
    ".DocumentRevisions-V100"       # version store
    ".PKInstallSandboxManager"      # installer sandbox
    "__MACOSX"                      # zip resource fork container

    # Linux / general
    ".Trash-*"                      # per-user trash
    "lost+found"                    # fsck recovery dir
    ".cache"                        # generic cache dir
    ".thumbnails"                   # GNOME thumbnail cache
    ".gvfs"                         # GNOME VFS mount point
)

# ── Sanity checks ─────────────────────────────────────────────────────────────
if [[ -z "$SOURCE_ROOT" ]]; then
    echo "ERROR: No source folder specified."
    echo "Usage: $0 <source_folder>"
    exit 1
fi

SOURCE_ROOT="$(realpath "$SOURCE_ROOT")"

if [[ ! -d "$SOURCE_ROOT" ]]; then
    echo "ERROR: Source folder does not exist: $SOURCE_ROOT"
    exit 1
fi

# Never let source accidentally point at cepheus
if [[ "$SOURCE_ROOT" == "$CEPHEUS_ROOT"* ]]; then
    echo "ERROR: Source folder is inside CEPHEUS_ROOT — aborting to prevent data loss."
    exit 1
fi

# Ensure log directory exists
if [[ ! -d "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR" || {
        echo "ERROR: Could not create log directory: $LOG_DIR"
        exit 1
    }
fi

# ── Logging ───────────────────────────────────────────────────────────────────
datum=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/cleanup_${datum}.log"
touch "$LOG_FILE"

log() { echo "$*" | tee -a "$LOG_FILE"; }
log_action() {
    local tag="$1"; shift
    printf "[%s] %s\n" "$tag" "$*" | tee -a "$LOG_FILE"
}

log "############################################################"
log "  cleanup_transfer.sh  —  started $datum"
log "  Source  : $SOURCE_ROOT"
log "  Cepheus : $CEPHEUS_ROOT"
log "  Log     : $LOG_FILE"
if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  MODE    : DRY-RUN (no files will be deleted)"
    log "  To run for real: DRY_RUN=0 $0 $SOURCE_ROOT"
else
    log "  MODE    : LIVE (files WILL be deleted)"
fi
log "############################################################"

# ── Helper functions ──────────────────────────────────────────────────────────

get_md5() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    md5sum "$f" | awk '{print $1}'
}

# Returns candidate cepheus paths for a relative sub-path
get_cepheus_paths() {
    local rel="$1"
    local clean="${rel#secure/}"
    echo "$CEPHEUS_ROOT/$clean"
    echo "$CEPHEUS_ROOT/secure/$clean"
}

safe_rm_file() {
    local f="$1"
    local reason="$2"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_action "DRY-RM" "$f  ($reason)"
    else
        rm -f "$f" && log_action "DELETED" "$f  ($reason)" || log_action "ERROR" "Could not delete $f"
    fi
}

safe_rm_dir() {
    local d="$1"
    local reason="$2"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log_action "DRY-RMDIR" "$d  ($reason)"
    else
        rm -rf "$d" && log_action "RMDIR" "$d  ($reason)" || log_action "ERROR" "Could not remove dir $d"
    fi
}

# ── Counters ──────────────────────────────────────────────────────────────────
cnt_verified=0
cnt_no_match=0
cnt_deleted=0
cnt_meta=0
cnt_hidden=0
cnt_system=0
cnt_empty_dirs=0

# ── PHASE 1 : MD5-verified deletion ───────────────────────────────────────────
log ""
log "═══ PHASE 1: MD5 verification and deletion ═══"

# Find lowest-level (leaf) directories
mapfile -t leaf_dirs < <(
    find "$SOURCE_ROOT" -mindepth 1 -type d \
        ! -exec sh -c 'find "$1" -mindepth 1 -type d -not -name ".*" | grep -q .' sh {} \; \
        -print | sort
)

# Process files directly in SOURCE_ROOT (flat / no sub-folder structure)
process_single_file() {
    local f="$1"
    local rel="${f#$SOURCE_ROOT/}"
    local src_md5
    src_md5=$(get_md5 "$f") || { log_action "SKIP" "$f (md5 failed)"; return; }

    local found=0
    while IFS= read -r cpath; do
        [[ -d "$cpath" ]] || continue
        while IFS= read -r -d '' cf; do
            local cf_md5
            cf_md5=$(get_md5 "$cf") || continue
            if [[ "$cf_md5" == "$src_md5" ]]; then
                found=1
                break 2
            fi
        done < <(find "$cpath" -type f -print0 2>/dev/null)
    done < <(get_cepheus_paths "$(dirname "$rel")")

    if [[ "$found" -eq 1 ]]; then
        ((cnt_verified++)) || true
        safe_rm_file "$f" "MD5 confirmed in cepheus"
        ((cnt_deleted++)) || true
    else
        ((cnt_no_match++)) || true
        log_action "KEEP" "$f  (not found in cepheus by MD5)"
    fi
}

process_leaf_folder() {
    local folder="$1"
    local rel="${folder#$SOURCE_ROOT/}"

    log ""
    log "  Folder: $rel"

    # Build source MD5 map
    declare -A src_map   # md5 -> filepath
    while IFS= read -r -d '' f; do
        local md5
        md5=$(get_md5 "$f") || continue
        src_map["$md5"]="$f"
    done < <(find "$folder" -type f -print0 2>/dev/null)

    local total_src=${#src_map[@]}
    [[ $total_src -eq 0 ]] && log "    (no files)" && return

    # Build cepheus MD5 map for candidate directories
    declare -A ceph_map  # md5 -> 1
    while IFS= read -r cdir; do
        [[ -d "$cdir" ]] || continue
        while IFS= read -r -d '' cf; do
            local cmd5
            cmd5=$(get_md5 "$cf") || continue
            ceph_map["$cmd5"]=1
        done < <(find "$cdir" -type f -print0 2>/dev/null)
    done < <(get_cepheus_paths "$rel")

    # Match source files against cepheus hashes
    local matched=()
    for md5 in "${!src_map[@]}"; do
        if [[ -n "${ceph_map[$md5]+x}" ]]; then
            matched+=("${src_map[$md5]}")
        fi
    done

    log "    Source files  : $total_src"
    log "    Ceph matches  : ${#matched[@]}"

    if [[ "${#matched[@]}" -eq "$total_src" && "$total_src" -gt 0 ]]; then
        log "    → ALL matched — deleting entire folder"
        ((cnt_verified += total_src)) || true
        safe_rm_dir "$folder" "all files MD5-confirmed in cepheus"
        ((cnt_deleted += total_src)) || true
    elif [[ "${#matched[@]}" -gt 0 ]]; then
        log "    → PARTIAL match — deleting ${#matched[@]} confirmed file(s)"
        for f in "${matched[@]}"; do
            ((cnt_verified++)) || true
            safe_rm_file "$f" "MD5 confirmed in cepheus"
            ((cnt_deleted++)) || true
        done
    else
        ((cnt_no_match += total_src)) || true
        log "    → No matches — nothing deleted"
    fi
}

if [[ ${#leaf_dirs[@]} -gt 0 ]]; then
    for d in "${leaf_dirs[@]}"; do
        process_leaf_folder "$d"
    done
else
    while IFS= read -r -d '' f; do
        process_single_file "$f"
    done < <(find "$SOURCE_ROOT" -maxdepth 1 -type f -print0)
fi

# ── PHASE 2 : Remove metadata / checksum files ────────────────────────────────
log ""
log "═══ PHASE 2: Metadata / checksum file removal ═══"

for pattern in "${METADATA_PATTERNS[@]}"; do
    while IFS= read -r -d '' f; do
        [[ "$f" -ef "$LOG_FILE" ]] && continue
        safe_rm_file "$f" "metadata pattern: $pattern"
        ((cnt_meta++)) || true
    done < <(find "$SOURCE_ROOT" -type f -iname "$pattern" -print0 2>/dev/null)
done

# ── PHASE 3 : Remove hidden files and folders ─────────────────────────────────
log ""
log "═══ PHASE 3: Hidden files and folders ═══"

while IFS= read -r -d '' item; do
    if [[ -f "$item" ]]; then
        safe_rm_file "$item" "hidden file"
    elif [[ -d "$item" ]]; then
        safe_rm_dir "$item" "hidden directory"
    fi
    ((cnt_hidden++)) || true
done < <(find "$SOURCE_ROOT" -mindepth 1 -name '.*' -print0 2>/dev/null)

# ── PHASE 4 : OS / system junk ───────────────────────────────────────────────
log ""
log "═══ PHASE 4: OS/system junk (Windows + macOS + Linux) ═══"

# Junk files
for pattern in "${JUNK_FILES[@]}"; do
    while IFS= read -r -d '' item; do
        [[ -f "$item" ]] || continue
        [[ "$item" -ef "$LOG_FILE" ]] && continue
        safe_rm_file "$item" "junk file: $pattern"
        ((cnt_system++)) || true
    done < <(find "$SOURCE_ROOT" -mindepth 1 -type f -iname "$pattern" -print0 2>/dev/null)
done

# Junk directories
for pattern in "${JUNK_DIRS[@]}"; do
    while IFS= read -r -d '' item; do
        [[ -d "$item" ]] || continue
        safe_rm_dir "$item" "junk dir: $pattern"
        ((cnt_system++)) || true
    done < <(find "$SOURCE_ROOT" -mindepth 1 -type d -iname "$pattern" -print0 2>/dev/null)
done

# ── PHASE 5 : Remove empty directories (bottom-up) ───────────────────────────
log ""
log "═══ PHASE 5: Empty directory removal ═══"

if [[ "$DRY_RUN" -eq 1 ]]; then
    while IFS= read -r d; do
        log_action "DRY-RMDIR" "$d  (empty)"
        ((cnt_empty_dirs++)) || true
    done < <(find "$SOURCE_ROOT" -mindepth 1 -type d -empty | sort -r)
else
    while IFS= read -r d; do
        rmdir "$d" 2>/dev/null && {
            log_action "RMDIR" "$d  (empty)"
            ((cnt_empty_dirs++)) || true
        } || true
    done < <(find "$SOURCE_ROOT" -mindepth 1 -type d | sort -r)
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log ""
log "############################################################"
log "  SUMMARY"
log "────────────────────────────────────────────────────────────"
log "  MD5-verified files found   : $cnt_verified"
log "  Files/folders deleted(P1)  : $cnt_deleted"
log "  Files NOT in cepheus(kept) : $cnt_no_match"
log "  Metadata files removed     : $cnt_meta"
log "  Hidden items removed       : $cnt_hidden"
log "  System/junk items removed  : $cnt_system"
log "  Empty dirs removed         : $cnt_empty_dirs"
if [[ "$DRY_RUN" -eq 1 ]]; then
    log ""
    log "  *** DRY-RUN — nothing was actually deleted ***"
    log "  *** Run with DRY_RUN=0 to perform real cleanup ***"
fi
log "############################################################"
log "Log saved to: $LOG_FILE"