#!/usr/bin/env bash

###############################################################################
# Script Name: hstam_architekturzeichnungen_restructure.sh
# Version: 3.1
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
Usage:
  $0 [OPTIONS] input.csv

Options:
  -h, --help        Show this help
  -v, --verbose     Verbose output
  -n, --dry-run     Dry run (no filesystem changes)

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
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            CSV_INPUT="$1"
            ;;
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
    if [[ "${VERBOSE:-0}" -eq 1 ]]; then
        echo "[$level] $*"
    fi
}

progress() {
    echo "→ $1"
    log INFO "$1"
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
fs() {
    local cmd="$1"
    shift
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] $cmd $*"
        log INFO "[DRY-RUN] $cmd $*"
        # Return success for dry-run to allow validation to continue
        return 0
    else
        "$cmd" "$@"
        return $?
    fi
}

# Special mkdir wrapper for dry-run
fs_mkdir() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] mkdir -p $*"
        log INFO "[DRY-RUN] mkdir -p $*"
        return 0
    else
        mkdir -p "$@"
        return $?
    fi
}

# Special mv wrapper for dry-run
fs_mv() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] mv $*"
        log INFO "[DRY-RUN] mv $*"
        return 0
    else
        mv "$@"
        return $?
    fi
}

# Special rm wrapper for dry-run
fs_rm() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] rm $*"
        log INFO "[DRY-RUN] rm $*"
        return 0
    else
        rm "$@"
        return $?
    fi
}

# Special ln wrapper for dry-run
fs_ln() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] ln $*"
        log INFO "[DRY-RUN] ln $*"
        return 0
    else
        ln "$@"
        return $?
    fi
}

# Special rmdir wrapper for dry-run
fs_rmdir() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] rmdir $*"
        log INFO "[DRY-RUN] rmdir $*"
        return 0
    else
        rmdir "$@"
        return $?
    fi
}

###############################################################################
# NORMALIZE SIGNATURE
# Karten P II 3614/3  -> p_ii_3614--3
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
                log INFO "Skipping header line: $c1"
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
            [[ "$VERBOSE" -eq 1 ]] && echo "Line $line_num: Skipping - c1 (architekturzeichnung) empty"
            count_skipped=$((count_skipped + 1))
            continue
        fi
        
        # Check if c4 (old_signatur) is filled
        if [[ -z "$c4" ]]; then
            [[ "$VERBOSE" -eq 1 ]] && echo "Line $line_num: Skipping - c4 (old_signatur) empty"
            count_skipped=$((count_skipped + 1))
            continue
        fi
        
        # If c5 is empty, no change needed -> skip
        if [[ -z "$c5" ]]; then
            [[ "$VERBOSE" -eq 1 ]] && echo "Line $line_num: Skipping - c5 (new_signatur) empty, no change needed"
            count_skipped=$((count_skipped + 1))
            continue
        fi

        # Debug output
        if [[ "$VERBOSE" -eq 1 ]]; then
            echo "Line $line_num: c1='$c1', c4='$c4', c5='$c5', c6='${c6:-(empty)}', c7='${c7:-(empty)}'"
        fi

        # Check if columns 6 or 7 have content -> manual review
        if [[ -n "$c6" || -n "$c7" ]]; then
            echo "$c1;$c4;$c5;extra description present (c6='$c6', c7='$c7')" >> "$CSV_MANUAL"
            count_manual=$((count_manual + 1))
            log INFO "Manual review: $c1 (extra description in c6/c7)"
            continue
        fi

        # Check if both old and new are "Karten" Bestand
        if [[ "$c4" != Karten* || "$c5" != Karten* ]]; then
            echo "$c1;$c4;$c5;different Bestand (not Karten)" >> "$CSV_MANUAL"
            count_manual=$((count_manual + 1))
            log INFO "Manual review: $c1 (not Karten Bestand)"
            continue
        fi

        # Normalize signatures
        old_norm=$(normalize_signature "$c4")
        new_norm=$(normalize_signature "$c5")

        echo "$c1;$old_norm;$new_norm" >> "$CSV_PROCESS"
        count_process=$((count_process + 1))
        log INFO "To process: $c1 | $old_norm -> $new_norm"
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
            log WARN "Invalid: $a - architekturzeichnung not found"
            continue
        fi

        # For dry-run, skip physical path checks for new paths
        if [[ "$DRY_RUN" -eq 0 ]]; then
            # Check old path in cepheus
            if [[ ! -d "${CEPH_KARTEN}/${o}" ]]; then
                echo "$a;$o;$n;old_path not found in cepheus" >> "$CSV_MANUAL"
                sed -i "\|^${a};|d" "$tmp" 2>/dev/null || grep -v "^${a};" "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
                count_invalid=$((count_invalid + 1))
                log WARN "Invalid: $a - old_path not found in cepheus: $o"
                continue
            fi

            # Check old path in netapp
            if [[ ! -d "${NETAPP_KARTEN}/${o}" ]]; then
                echo "$a;$o;$n;old_path not found in netapp" >> "$CSV_MANUAL"
                sed -i "\|^${a};|d" "$tmp" 2>/dev/null || grep -v "^${a};" "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
                count_invalid=$((count_invalid + 1))
                log WARN "Invalid: $a - old_path not found in netapp: $o"
                continue
            fi

            # Check if new path already exists
            if [[ -d "${CEPH_KARTEN}/${n}" || -d "${NETAPP_KARTEN}/${n}" ]]; then
                echo "$a;$o;$n;new_path already exists" >> "$CSV_MANUAL"
                sed -i "\|^${a};|d" "$tmp" 2>/dev/null || grep -v "^${a};" "$tmp" > "${tmp}.new" && mv "${tmp}.new" "$tmp"
                count_invalid=$((count_invalid + 1))
                log WARN "Invalid: $a - new_path already exists: $n"
                continue
            fi
        else
            # In dry-run mode, just log the checks
            log INFO "DRY-RUN: Would check paths for $a: $o -> $n"
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
            log INFO "Created cepheus dir: ${CEPH_KARTEN}/${n}"
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
            log INFO "Created netapp dir: ${NETAPP_KARTEN}/${n}/thumbs"
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
    echo "  - Created: $count_created"
    echo "  - Failed: $count_failed"
    log SUCCESS "Directory creation: $count_created created, $count_failed failed"
}

###############################################################################
# PROCESS 4: CEPHEUS MOVE
###############################################################################
process_move_cepheus() {
    progress "Process 4: Move files in Cepheus"
    echo "old_signatur_files;new_signatur_files" > "$CSV_RENAMED"
    
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
                    echo "$oldfile;${dst_new}/$(basename "$oldfile")" >> "$CSV_RENAMED"
                    count_moved=$((count_moved + 1))
                    log INFO "Moved in cepheus: $oldfile -> $dst_new/"
                else
                    if [[ "$DRY_RUN" -eq 0 ]]; then
                        log ERROR "Failed to move in cepheus: $oldfile"
                    fi
                fi
            done
            
            if [[ $found -eq 0 ]] && [[ "$VERBOSE" -eq 1 ]]; then
                log WARN "No matching file found in cepheus for: $name"
            fi
        done
    done < "$CSV_PROCESS"
    
    progress "Cepheus move finished:"
    echo "  - Reference files checked: $count_files"
    echo "  - Files moved: $count_moved"
    log SUCCESS "Cepheus move: $count_moved files moved from $count_files reference files"
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
                    log INFO "Moved in netapp: $oldfile -> $dst_new/"
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
                    log INFO "Moved thumb in netapp: $thumbfile -> $dst_new/thumbs/"
                elif [[ "$DRY_RUN" -eq 0 ]]; then
                    log WARN "Could not move thumb in netapp: $thumbfile"
                fi
            done
        done
    done < "$CSV_PROCESS"

    progress "NetApp move finished:"
    echo "  - Main files moved: $count_moved"
    echo "  - Thumbnails moved: $count_thumbs"
    log SUCCESS "NetApp move: $count_moved files, $count_thumbs thumbs moved"
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
                    echo "[DRY-RUN] Would check and possibly delete: $p"
                    log INFO "[DRY-RUN] Would check for deletion: $p"
                    count_deleted=$((count_deleted + 1))
                fi
            else
                # Only delete if directory exists and is empty
                if [[ -d "$p" ]]; then
                    if [[ -z "$(ls -A "$p" 2>/dev/null)" ]]; then
                        if fs_rmdir "$p"; then
                            echo "$p" >> "$CSV_DELETED"
                            count_deleted=$((count_deleted + 1))
                            log INFO "Deleted empty dir: $p"
                        else
                            log WARN "Could not delete dir: $p"
                        fi
                    else
                        log INFO "Directory not empty, skipping: $p"
                    fi
                fi
            fi
        done
    done < "$CSV_PROCESS"

    progress "Cleanup finished:"
    echo "  - Directories removed: $count_deleted"
    log SUCCESS "Cleanup: $count_deleted directories removed"
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
            if fs_ln -s "${SYMLINK_BASE}/${n}/$(basename "$f")" "$linkdir/$(basename "$f")"; then
                count_links=$((count_links + 1))
            else
                if [[ "$DRY_RUN" -eq 0 ]]; then
                    log ERROR "Failed to create symlink: $linkdir/$(basename "$f")"
                fi
            fi
        done

        # Create new symlinks for thumbnails
        for f in "$target/thumbs"/*; do
            [[ -f "$f" ]] || continue
            if fs_ln -s "${SYMLINK_BASE}/${n}/thumbs/$(basename "$f")" "$linkdir/thumbs/$(basename "$f")"; then
                count_links=$((count_links + 1))
            else
                if [[ "$DRY_RUN" -eq 0 ]]; then
                    log ERROR "Failed to create thumb symlink: $linkdir/thumbs/$(basename "$f")"
                fi
            fi
        done
        
        log INFO "Recreated symlinks for: $a"
    done < "$CSV_PROCESS"

    progress "Symlink recreation finished:"
    echo "  - Old symlinks removed: $count_removed"
    echo "  - New symlinks created: $count_links"
    log SUCCESS "Symlink recreation: $count_removed removed, $count_links created"
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
    [[ "$DRY_RUN" -eq 1 ]] && progress "DRY-RUN MODE - No filesystem changes will be made" && log INFO "DRY-RUN enabled"
    [[ "$VERBOSE" -eq 1 ]] && progress "Verbose mode enabled"
    
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
    progress "  - Processing list:    $CSV_PROCESS"
    progress "  - Manual review:      $CSV_MANUAL"
    progress "  - Renamed files:      $CSV_RENAMED"
    progress "  - Deleted dirs:       $CSV_DELETED"
    progress "  - Log file:           $LOGFILE"
    progress ""
    
    # Show file counts
    local proc_count manual_count renamed_count deleted_count
    proc_count=$(wc -l < "$CSV_PROCESS" 2>/dev/null || echo "0")
    manual_count=$(wc -l < "$CSV_MANUAL" 2>/dev/null || echo "0")
    renamed_count=$(wc -l < "$CSV_RENAMED" 2>/dev/null || echo "0")
    deleted_count=$(wc -l < "$CSV_DELETED" 2>/dev/null || echo "0")
    
    progress "Summary:"
    progress "  - Entries processed:  $((proc_count - 1))"
    progress "  - Manual review:      $((manual_count - 1))"
    progress "  - Files renamed:      $((renamed_count - 1))"
    progress "  - Dirs deleted:       $((deleted_count - 1))"
    
	if [[ "$DRY_RUN" -eq 1 ]]; then
        progress ""
        progress "This was a DRY-RUN. No changes were made to the filesystem."
        progress "Remove the -n flag to execute the actual operations."
    fi
    
    log SUCCESS "Script completed successfully"
}

###############################################################################
# EXECUTE MAIN
###############################################################################
main

exit 0