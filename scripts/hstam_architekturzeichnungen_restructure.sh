#!/usr/bin/env bash

###############################################################################
# Script Name: hstam_architekturzeichnungen_restructure.sh
# Version: 3.3
# Author: Mustafa Demiroglu
# Organisation: HlaDigiTeam
#
# Purpose:
#   Controlled restructuring of HStAM architectural drawings and Karten
#
# Use-Definitions:
#   - Dry-run mode to properly simulate operations
#   - Header detection for CSV
#   - Lock file mechanism
#   - Disk space check
#   - Error handling
#   - Progress tracking
#   - Symlink path handling
###############################################################################

set -uo pipefail
IFS=$'\n\t'

###############################################################################
# ARGUMENTS
###############################################################################

VERBOSE=0
DRY_RUN=0
CSV_INPUT=""

show_help() {
    cat << EOF
Usage: $0 [OPTIONS] input.csv

Options:
  -h, --help      Show this help
  -v, --verbose   Verbose output
  -n, --dry-run   Dry run (no filesystem changes)

Example:
  $0 -v -n data.csv
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) show_help ;;
        -v|--verbose) VERBOSE=1 ;;
        -n|--dry-run) DRY_RUN=1 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) CSV_INPUT="$1" ;;
    esac
    shift
done

[[ -z "$CSV_INPUT" ]] && { echo "CSV input required"; exit 1; }
[[ ! -f "$CSV_INPUT" ]] && { echo "CSV not found: $CSV_INPUT"; exit 1; }

###############################################################################
# PATH CONFIG
###############################################################################

NETAPP_ROOT="/media/archive/public/www/hstam"
NETAPP_ARCH="${NETAPP_ROOT}/architekturzeichnungen"
NETAPP_KARTEN="${NETAPP_ROOT}/karten"
CEPH_ROOT="/media/cepheus/hstam"
CEPH_KARTEN="${CEPH_ROOT}/karten"

# Symlink base path (configurable)
SYMLINK_BASE="/archive/www/hstam/karten"

WORKDIR="/tmp/hstam_arch_process_$(date '+%Y%m%d_%H%M%S')_$$"
LOCKFILE="/tmp/hstam_arch_restructure.lock"
LOGFILE="${WORKDIR}/process.log"

CSV_PROCESS="${WORKDIR}/csv_to_be_processed.csv"
CSV_MANUAL="${WORKDIR}/csv_check_manuel.csv"
CSV_RENAMED="${WORKDIR}/renamed_signaturen.csv"
CSV_DELETED="${WORKDIR}/deleted_old_signaturen.csv"

###############################################################################
# LOCK FILE MECHANISM
###############################################################################

acquire_lock() {
    if [[ -f "$LOCKFILE" ]]; then
        echo "ERROR: Another instance is running (lock file exists: $LOCKFILE)"
        echo "If you're sure no other instance is running, remove the lock file manually."
        exit 1
    fi
    echo $$ > "$LOCKFILE"
}

release_lock() {
    rm -f "$LOCKFILE"
}

trap release_lock EXIT INT TERM

###############################################################################
# SETUP
###############################################################################

mkdir -p "$WORKDIR"

###############################################################################
# LOGGING
###############################################################################

log() {
    local level="$1"; shift
    echo "$(date '+%F %T') [$level] $*" >> "$LOGFILE"
}

progress() {
    echo "→ $1"
    log INFO "$1"
}

verbose_log() {
    log INFO "$@"
    if [[ "$VERBOSE" -eq 1 ]]; then
        echo "$@"
    fi
}

###############################################################################
# PRE-FLIGHT CHECKS
###############################################################################

preflight_checks() {
    progress "Running pre-flight checks..."

    # Check if paths exist
    for path in "$NETAPP_ROOT" "$NETAPP_ARCH" "$NETAPP_KARTEN" "$CEPH_ROOT" "$CEPH_KARTEN"; do
        if [[ ! -d "$path" ]]; then
            echo "ERROR: Required path does not exist: $path"
            exit 1
        fi
    done

    # Check disk space (at least 1GB free on both)
    local netapp_free ceph_free
    netapp_free=$(df -BG "$NETAPP_ROOT" | awk 'NR==2 {print $4}' | sed 's/G//')
    ceph_free=$(df -BG "$CEPH_ROOT" | awk 'NR==2 {print $4}' | sed 's/G//')

    if [[ "$netapp_free" -lt 1 ]]; then
        echo "WARNING: Less than 1GB free on NetApp: ${netapp_free}GB"
        log WARN "Low disk space on NetApp: ${netapp_free}GB"
    fi

    if [[ "$ceph_free" -lt 1 ]]; then
        echo "WARNING: Less than 1GB free on Ceph: ${ceph_free}GB"
        log WARN "Low disk space on Ceph: ${ceph_free}GB"
    fi

    # Check write permissions
    if [[ "$DRY_RUN" -eq 0 ]]; then
        for path in "$NETAPP_ARCH" "$NETAPP_KARTEN" "$CEPH_KARTEN"; do
            if [[ ! -w "$path" ]]; then
                echo "ERROR: No write permission: $path"
                exit 1
            fi
        done
    fi

    progress "Pre-flight checks completed"
}

###############################################################################
# SAFE EXIT IF CSV EMPTY
###############################################################################

ensure_non_empty_process_csv() {
    local lines
    lines=$(wc -l < "$CSV_PROCESS" 2>/dev/null || echo 0)
    if [[ "$lines" -le 1 ]]; then
        progress "No valid entries to process – stopping pipeline gracefully"
        log WARN "CSV_PROCESS contains no actionable rows"
        return 1
    fi
    return 0
}

###############################################################################
# SAFE FS OPS (DRY-RUN WRAPPER)
###############################################################################

# Special mkdir wrapper for dry-run
fs_mkdir() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        verbose_log "[DRY-RUN] would execute: mkdir -p $*"
        return 0
    else
        verbose_log "Executing: mkdir -p $*"
        mkdir -p "$@"
        return $?
    fi
}

# Special mv wrapper for dry-run
fs_mv() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        verbose_log "[DRY-RUN] would execute: mv $*"
        return 0
    else
        verbose_log "Executing: mv $*"
        mv "$@"
        return $?
    fi
}

# Special rm wrapper for dry-run
fs_rm() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        verbose_log "[DRY-RUN] would execute: rm $*"
        return 0
    else
        verbose_log "Executing: rm $*"
        rm "$@"
        return $?
    fi
}

# Special ln wrapper for dry-run
fs_ln() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        verbose_log "[DRY-RUN] would execute: ln $*"
        return 0
    else
        verbose_log "Executing: ln $*"
        ln "$@"
        return $?
    fi
}

# Special rmdir wrapper for dry-run
fs_rmdir() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        verbose_log "[DRY-RUN] would execute: rmdir $*"
        return 0
    else
        verbose_log "Executing: rmdir $*"
        rmdir "$@"
        return $?
    fi
}

###############################################################################
# NORMALIZE SIGNATURE
# Karten P II 3614/3 -> p_ii_3614--3
###############################################################################

normalize_signature() {
    local s="$1"
    s="${s#Karten }"
    echo "$s" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[[:space:]]+/_/g; s|/|--|g'
}

###############################################################################
# PROCESS 1: CSV TRANSFORMATION
###############################################################################

process_csv_transform() {
    progress "Process 1: CSV transformation"

    echo "architekturzeichnung;old_path;new_path" > "$CSV_PROCESS"
    echo "architekturzeichnung;old_path;new_path;reason" > "$CSV_MANUAL"

    local count_process=0
    local count_manual=0
    local count_skipped=0
    local line_num=0
    local is_header=1

    while IFS=';' read -r c1 c2 c3 c4 c5 c6 c7 rest; do
        line_num=$((line_num + 1))

        # Clean Windows line endings
        c1="${c1%$'\r'}"; c2="${c2%$'\r'}"; c3="${c3%$'\r'}"
        c4="${c4%$'\r'}"; c5="${c5%$'\r'}"; c6="${c6%$'\r'}"; c7="${c7%$'\r'}"

        # Skip header line (first non-empty line with expected column names)
        if [[ $is_header -eq 1 ]]; then
            if [[ "$c1" =~ ^[Aa]rchitekturzeichnung$ ]] || [[ "$c1" =~ ^[Cc]olumn ]] || [[ "$c1" =~ ^[Nn]ame ]]; then
                verbose_log "Skipping header line: $c1"
                is_header=0
                continue
            fi
            is_header=0
        fi

        # Skip empty lines
        if [[ -z "$c1" && -z "$c4" && -z "$c5" ]]; then
            count_skipped=$((count_skipped + 1))
            continue
        fi

        # Check if c1 (architekturzeichnung) is empty
        if [[ -z "$c1" ]]; then
            verbose_log "Line $line_num: Skipping - c1 (architekturzeichnung) empty"
            count_skipped=$((count_skipped + 1))
            continue
        fi

        # Check if c4 (old_signatur) is filled
        if [[ -z "$c4" ]]; then
            verbose_log "Line $line_num: Skipping - c4 (old_signatur) empty"
            count_skipped=$((count_skipped + 1))
            continue
        fi

        # If c5 is empty, no change needed -> skip
        if [[ -z "$c5" ]]; then
            verbose_log "Line $line_num: Skipping - c5 (new_signatur) empty, no change needed"
            count_skipped=$((count_skipped + 1))
            continue
        fi

        # Debug output
        verbose_log "Line $line_num: c1='$c1', c4='$c4', c5='$c5', c6='${c6:-(empty)}', c7='${c7:-(empty)}'"

        # Check if columns 6 or 7 have content -> manual review
        if [[ -n "$c6" || -n "$c7" ]]; then
            echo "$c1;$c4;$c5;extra description present (c6='$c6', c7='$c7')" >> "$CSV_MANUAL"
            count_manual=$((count_manual + 1))
            verbose_log "Manual review: $c1 (extra description in c6/c7)"
            continue
        fi

        # Check if both old and new are "Karten" Bestand
        if [[ "$c4" != Karten* || "$c5" != Karten* ]]; then
            echo "$c1;$c4;$c5;different Bestand (not Karten)" >> "$CSV_MANUAL"
            count_manual=$((count_manual + 1))
            verbose_log "Manual review: $c1 (not Karten Bestand)"
            continue
        fi

        # Normalize signatures
        old_norm=$(normalize_signature "$c4")
        new_norm=$(normalize_signature "$c5")

        echo "$c1;$old_norm;$new_norm" >> "$CSV_PROCESS"
        count_process=$((count_process + 1))
        verbose_log "To process: $c1 | $old_norm -> $new_norm"

    done < "$CSV_INPUT"

    progress "CSV transformation finished:"
    echo "  - To process: $count_process"
    echo "  - Manual review: $count_manual"
    echo "  - Skipped: $count_skipped"
    log SUCCESS "CSV transformation: $count_process to process, $count_manual manual, $count_skipped skipped"
}

###############################################################################
# PROCESS 2: PATH VALIDATION
###############################################################################

process_validate_paths() {
    progress "Process 2: Path validation"

    tmp="${CSV_PROCESS}.tmp"
    cp "$CSV_PROCESS" "$tmp"

    local count_valid=0
    local count_invalid=0

    while IFS=';' read -r a o n || [[ -n "${a:-}" ]]; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        # Check architekturzeichnung directory
        if [[ ! -d "${NETAPP_ARCH}/${a}" ]]; then
            echo "$a;$o;$n;architekturzeichnung not found" >> "$CSV_MANUAL"
            sed -i "\|^${a};|d" "$tmp" 2>/dev/null || grep -v "^${a};" "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
            count_invalid=$((count_invalid + 1))
            verbose_log "Invalid: $a - architekturzeichnung not found"
            continue
        fi

        # For dry-run, skip physical path checks for new paths
        if [[ "$DRY_RUN" -eq 0 ]]; then
            # Check old path in cepheus
            if [[ ! -d "${CEPH_KARTEN}/${o}" ]]; then
                echo "$a;$o;$n;old_path not found in cepheus" >> "$CSV_MANUAL"
                sed -i "\|^${a};|d" "$tmp" 2>/dev/null || grep -v "^${a};" "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
                count_invalid=$((count_invalid + 1))
                verbose_log "Invalid: $a - old_path not found in cepheus: $o"
                continue
            fi

            # Check old path in netapp
            if [[ ! -d "${NETAPP_KARTEN}/${o}" ]]; then
                echo "$a;$o;$n;old_path not found in netapp" >> "$CSV_MANUAL"
                sed -i "\|^${a};|d" "$tmp" 2>/dev/null || grep -v "^${a};" "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
                count_invalid=$((count_invalid + 1))
                verbose_log "Invalid: $a - old_path not found in netapp: $o"
                continue
            fi

            # Check if new path already exists
            if [[ -d "${CEPH_KARTEN}/${n}" || -d "${NETAPP_KARTEN}/${n}" ]]; then
                echo "$a;$o;$n;new_path already exists" >> "$CSV_MANUAL"
                sed -i "\|^${a};|d" "$tmp" 2>/dev/null || grep -v "^${a};" "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
                count_invalid=$((count_invalid + 1))
                verbose_log "Invalid: $a - new_path already exists: $n"
                continue
            fi
        else
            # In dry-run mode, just log the checks
            verbose_log "DRY-RUN: Would check paths for $a: $o -> $n"
        fi

        count_valid=$((count_valid + 1))

    done < "$CSV_PROCESS"

    mv "$tmp" "$CSV_PROCESS"

    progress "Path validation finished:"
    echo "  - Valid: $count_valid"
    echo "  - Invalid: $count_invalid"
    log SUCCESS "Path validation: $count_valid valid, $count_invalid invalid"
}

###############################################################################
# PROCESS 3: CREATE NEW DIRECTORIES
###############################################################################

process_create_dirs() {
    progress "Process 3: Create new directories"

    tmp="${CSV_PROCESS}.tmp"
    cp "$CSV_PROCESS" "$tmp"

    local count_created=0
    local count_failed=0

    while IFS=';' read -r a o n || [[ -n "${a:-}" ]]; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        if fs_mkdir "${CEPH_KARTEN}/${n}"; then
            if [[ "$DRY_RUN" -eq 1 ]]; then
                verbose_log "Would create cepheus dir: ${CEPH_KARTEN}/${n}"
            else
                verbose_log "Created cepheus dir: ${CEPH_KARTEN}/${n}"
            fi
        else
            if [[ "$DRY_RUN" -eq 0 ]]; then
                echo "$a;$o;$n;cannot create cepheus dir" >> "$CSV_MANUAL"
                sed -i "\|^${a};|d" "$tmp" 2>/dev/null || grep -v "^${a};" "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
                count_failed=$((count_failed + 1))
                log ERROR "Failed to create cepheus dir: ${CEPH_KARTEN}/${n}"
                continue
            fi
        fi

        if fs_mkdir "${NETAPP_KARTEN}/${n}/thumbs"; then
            if [[ "$DRY_RUN" -eq 1 ]]; then
                verbose_log "Would create netapp dir: ${NETAPP_KARTEN}/${n}/thumbs"
            else
                verbose_log "Created netapp dir: ${NETAPP_KARTEN}/${n}/thumbs"
            fi
            count_created=$((count_created + 1))
        else
            if [[ "$DRY_RUN" -eq 0 ]]; then
                echo "$a;$o;$n;cannot create netapp dir" >> "$CSV_MANUAL"
                sed -i "\|^${a};|d" "$tmp" 2>/dev/null || grep -v "^${a};" "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
                count_failed=$((count_failed + 1))
                log ERROR "Failed to create netapp dir: ${NETAPP_KARTEN}/${n}"
            fi
        fi

    done < "$CSV_PROCESS"

    mv "$tmp" "$CSV_PROCESS"

    progress "Directory creation finished:"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  - Would create: $count_created"
        echo "  - Would fail: $count_failed"
        log SUCCESS "Directory creation (DRY-RUN): $count_created would be created, $count_failed would fail"
    else
        echo "  - Created: $count_created"
        echo "  - Failed: $count_failed"
        log SUCCESS "Directory creation: $count_created created, $count_failed failed"
    fi
}

###############################################################################
# PROCESS 4: CEPHEUS MOVE
###############################################################################

process_move_cepheus() {
    progress "Process 4: Move files in Cepheus"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "architekturzeichnung;old_signatur_files;new_signatur_files;note" > "$CSV_RENAMED"
        echo "[DRY-RUN] This list shows what WOULD be renamed" >> "$CSV_RENAMED"
    else
        echo "old_signatur_files;new_signatur_files" > "$CSV_RENAMED"
    fi

    local count_moved=0
    local count_files=0

    while IFS=';' read -r a o n || [[ -n "${a:-}" ]]; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        src_arch="${NETAPP_ARCH}/${a}"
        src_old="${CEPH_KARTEN}/${o}"
        dst_new="${CEPH_KARTEN}/${n}"

        # Count files first (excluding thumbs directory)
        for f in "$src_arch"/*; do
            [[ "$f" == */thumbs ]] && continue
            [[ "$f" == */thumbs/* ]] && continue
            [[ ! -f "$f" ]] && continue
            count_files=$((count_files + 1))
        done

        for f in "$src_arch"/*; do
            [[ "$f" == */thumbs ]] && continue
            [[ "$f" == */thumbs/* ]] && continue
            [[ ! -f "$f" ]] && continue

            name="$(basename "${f%.*}")"

            # Find matching files in old location
            local found=0
            for oldfile in "$src_old"/${name}.*; do
                # Check if glob matched anything
                [[ ! -e "$oldfile" ]] && continue
                [[ ! -f "$oldfile" ]] && continue

                found=1

                if fs_mv "$oldfile" "$dst_new/"; then
                    if [[ "$DRY_RUN" -eq 1 ]]; then
                        echo "$a;$oldfile;${dst_new}/$(basename "$oldfile");would move" >> "$CSV_RENAMED"
                        verbose_log "Would move in cepheus: $oldfile -> $dst_new/"
                    else
                        echo "$oldfile;${dst_new}/$(basename "$oldfile")" >> "$CSV_RENAMED"
                        verbose_log "Moved in cepheus: $oldfile -> $dst_new/"
                    fi
                    count_moved=$((count_moved + 1))
                else
                    if [[ "$DRY_RUN" -eq 0 ]]; then
                        log ERROR "Failed to move in cepheus: $oldfile"
                    fi
                fi
            done

            if [[ $found -eq 0 ]]; then
                verbose_log "No matching file found in cepheus for: $name"
            fi
        done

    done < "$CSV_PROCESS"

    progress "Cepheus move finished:"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  - Reference files checked: $count_files"
        echo "  - Would move: $count_moved files"
        log SUCCESS "Cepheus move (DRY-RUN): $count_moved files would be moved from $count_files reference files"
    else
        echo "  - Reference files checked: $count_files"
        echo "  - Files moved: $count_moved"
        log SUCCESS "Cepheus move: $count_moved files moved from $count_files reference files"
    fi
}

###############################################################################
# PROCESS 5: NETAPP MOVE
###############################################################################

process_move_netapp() {
    progress "Process 5: Move files in NetApp"

    local count_moved=0
    local count_thumbs=0

    while IFS=';' read -r a o n || [[ -n "${a:-}" ]]; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        src_arch="${NETAPP_ARCH}/${a}"
        src_old="${NETAPP_KARTEN}/${o}"
        dst_new="${NETAPP_KARTEN}/${n}"

        for f in "$src_arch"/*; do
            [[ "$f" == */thumbs ]] && continue
            [[ "$f" == */thumbs/* ]] && continue
            [[ ! -f "$f" ]] && continue

            name="$(basename "${f%.*}")"

            # Move main files
            for oldfile in "$src_old"/${name}.*; do
                [[ ! -e "$oldfile" ]] && continue
                [[ ! -f "$oldfile" ]] && continue

                if fs_mv "$oldfile" "$dst_new/" 2>/dev/null; then
                    count_moved=$((count_moved + 1))
                    if [[ "$DRY_RUN" -eq 1 ]]; then
                        verbose_log "Would move in netapp: $oldfile -> $dst_new/"
                    else
                        verbose_log "Moved in netapp: $oldfile -> $dst_new/"
                    fi
                elif [[ "$DRY_RUN" -eq 0 ]]; then
                    log WARN "Could not move in netapp: $oldfile"
                fi
            done

            # Move thumbnails
            for thumbfile in "$src_old"/thumbs/${name}.*; do
                [[ ! -e "$thumbfile" ]] && continue
                [[ ! -f "$thumbfile" ]] && continue

                if fs_mv "$thumbfile" "$dst_new/thumbs/" 2>/dev/null; then
                    count_thumbs=$((count_thumbs + 1))
                    if [[ "$DRY_RUN" -eq 1 ]]; then
                        verbose_log "Would move thumb in netapp: $thumbfile -> $dst_new/thumbs/"
                    else
                        verbose_log "Moved thumb in netapp: $thumbfile -> $dst_new/thumbs/"
                    fi
                elif [[ "$DRY_RUN" -eq 0 ]]; then
                    log WARN "Could not move thumb in netapp: $thumbfile"
                fi
            done
        done

    done < "$CSV_PROCESS"

    progress "NetApp move finished:"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  - Would move main files: $count_moved"
        echo "  - Would move thumbnails: $count_thumbs"
        log SUCCESS "NetApp move (DRY-RUN): $count_moved files, $count_thumbs thumbs would be moved"
    else
        echo "  - Main files moved: $count_moved"
        echo "  - Thumbnails moved: $count_thumbs"
        log SUCCESS "NetApp move: $count_moved files, $count_thumbs thumbs moved"
    fi
}

###############################################################################
# PROCESS 6: DELETE EMPTY OLD DIRS
###############################################################################

process_cleanup_dirs() {
    progress "Process 6: Remove empty old directories"

    echo "deleted_path" > "$CSV_DELETED"

    local count_deleted=0

    while IFS=';' read -r _ o _; do
        [[ "$o" == "old_path" ]] && continue

        for p in "${CEPH_KARTEN}/${o}" "${NETAPP_KARTEN}/${o}/thumbs" "${NETAPP_KARTEN}/${o}"; do
            if [[ "$DRY_RUN" -eq 1 ]]; then
                # In dry-run, just log what would be deleted
                if [[ -d "$p" ]]; then
                    verbose_log "Would check and possibly delete: $p"
                    count_deleted=$((count_deleted + 1))
                fi
            else
                # Only delete if directory exists and is empty
                if [[ -d "$p" ]]; then
                    if [[ -z "$(ls -A "$p" 2>/dev/null)" ]]; then
                        if fs_rmdir "$p"; then
                            echo "$p" >> "$CSV_DELETED"
                            count_deleted=$((count_deleted + 1))
                            verbose_log "Deleted empty dir: $p"
                        else
                            log WARN "Could not delete dir: $p"
                        fi
                    else
                        verbose_log "Directory not empty, skipping: $p"
                    fi
                fi
            fi
        done

    done < "$CSV_PROCESS"

    progress "Cleanup finished:"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  - Would remove: $count_deleted directories"
        log SUCCESS "Cleanup (DRY-RUN): $count_deleted directories would be removed"
    else
        echo "  - Directories removed: $count_deleted"
        log SUCCESS "Cleanup: $count_deleted directories removed"
    fi
}

###############################################################################
# PROCESS 7: RECREATE SYMLINKS
###############################################################################

process_symlinks() {
    progress "Process 7: Recreate symlinks"

    local count_links=0
    local count_removed=0

    while IFS=';' read -r a _ n; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        target="${NETAPP_KARTEN}/${n}"
        linkdir="${NETAPP_ARCH}/${a}"

        # Remove old symlinks
        for old_link in "$linkdir"/* "$linkdir"/thumbs/*; do
            [[ -L "$old_link" ]] || continue
            if fs_rm -f "$old_link" 2>/dev/null; then
                count_removed=$((count_removed + 1))
            fi
        done

        # Create new symlinks for main files
        for f in "$target"/*; do
            [[ -f "$f" ]] || continue
            
            local symlink_target="${SYMLINK_BASE}/${n}/$(basename "$f")"
            local symlink_path="$linkdir/$(basename "$f")"
            
            if fs_ln -s "$symlink_target" "$symlink_path"; then
                count_links=$((count_links + 1))
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    verbose_log "Would create symlink: $symlink_path -> $symlink_target"
                else
                    verbose_log "Created symlink: $symlink_path -> $symlink_target"
                fi
            else
                if [[ "$DRY_RUN" -eq 0 ]]; then
                    log ERROR "Failed to create symlink: $symlink_path"
                fi
            fi
        done

        # Create new symlinks for thumbnails
        for f in "$target/thumbs"/*; do
            [[ -f "$f" ]] || continue
            
            local symlink_target="${SYMLINK_BASE}/${n}/thumbs/$(basename "$f")"
            local symlink_path="$linkdir/thumbs/$(basename "$f")"
            
            if fs_ln -s "$symlink_target" "$symlink_path"; then
                count_links=$((count_links + 1))
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    verbose_log "Would create thumb symlink: $symlink_path -> $symlink_target"
                else
                    verbose_log "Created thumb symlink: $symlink_path -> $symlink_target"
                fi
            else
                if [[ "$DRY_RUN" -eq 0 ]]; then
                    log ERROR "Failed to create thumb symlink: $symlink_path"
                fi
            fi
        done

        verbose_log "Recreated symlinks for: $a"

    done < "$CSV_PROCESS"

    progress "Symlink recreation finished:"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  - Would remove old symlinks: $count_removed"
        echo "  - Would create new symlinks: $count_links"
        log SUCCESS "Symlink recreation (DRY-RUN): $count_removed would be removed, $count_links would be created"
    else
        echo "  - Old symlinks removed: $count_removed"
        echo "  - New symlinks created: $count_links"
        log SUCCESS "Symlink recreation: $count_removed removed, $count_links created"
    fi
}

###############################################################################
# PROCESS 8: CHECKSUM (PLACEHOLDER)
###############################################################################

process_checksum() {
    progress "Process 8: Checksum update"
    log INFO "Checksum update will be implemented later"
    progress "Checksum update - to be implemented"
}

###############################################################################
# MAIN
###############################################################################

main() {
    acquire_lock

    progress "========================================"
    progress "HStAM Archive Restructuring Script"
    progress "========================================"
    progress "Working directory: $WORKDIR"
    log INFO "Script started"
    log INFO "CSV Input: $CSV_INPUT"
    log INFO "Working directory: $WORKDIR"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        progress "DRY-RUN MODE - No filesystem changes will be made"
        log INFO "DRY-RUN enabled"
    fi

    if [[ "$VERBOSE" -eq 1 ]]; then
        progress "Verbose mode enabled"
    fi

    preflight_checks

    progress ""
    progress "Starting processing pipeline..."
    progress ""

    process_csv_transform
    ensure_non_empty_process_csv || return 0
    process_validate_paths
    process_create_dirs
    process_move_cepheus
    process_move_netapp
    process_cleanup_dirs
    process_symlinks
    process_checksum

    progress ""
    progress "========================================"
    progress "All processes finished successfully"
    progress "========================================"
    progress ""
    progress "Results location: $WORKDIR"
    progress ""
    progress "Output files:"
    progress "  - Processing list: $CSV_PROCESS"
    progress "  - Manual review: $CSV_MANUAL"
    progress "  - Renamed files: $CSV_RENAMED"
    progress "  - Deleted dirs: $CSV_DELETED"
    progress "  - Log file: $LOGFILE"
    progress ""

    # Show file counts
    local proc_count manual_count renamed_count deleted_count
    proc_count=$(wc -l < "$CSV_PROCESS" 2>/dev/null || echo "0")
    manual_count=$(wc -l < "$CSV_MANUAL" 2>/dev/null || echo "0")
    renamed_count=$(wc -l < "$CSV_RENAMED" 2>/dev/null || echo "0")
    deleted_count=$(wc -l < "$CSV_DELETED" 2>/dev/null || echo "0")

    progress "Summary:"
    progress "  - Entries processed: $((proc_count - 1))"
    progress "  - Manual review: $((manual_count - 1))"
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        progress "  - Files that would be renamed: $((renamed_count - 2))"
        progress "  - Dirs that would be deleted: $((deleted_count - 1))"
    else
        progress "  - Files renamed: $((renamed_count - 1))"
        progress "  - Dirs deleted: $((deleted_count - 1))"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        progress ""
        progress "========================================"
        progress "This was a DRY-RUN. No changes were made to the filesystem."
        progress "Review the results and remove the -n flag to execute the actual operations."
        progress "========================================"
    fi

    log SUCCESS "Script completed successfully"
}

###############################################################################
# EXECUTE MAIN
###############################################################################

main
exit 0