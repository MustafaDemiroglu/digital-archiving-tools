#!/usr/bin/env bash
###############################################################################
# Script Name: hstam_architekturzeichnungen_restructure.sh
# Version: 3.3.3
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

WORKDIR="/tmp/hstam_arch_process_$(date '+%Y%m%d_%H%M%S')_$$"
LOCKFILE="/tmp/hstam_arch_restructure.lock"
LOGFILE="${WORKDIR}/process.log"

CSV_PROCESS="${WORKDIR}/csv_to_be_processed.csv"
CSV_MANUAL="${WORKDIR}/csv_check_manuel.csv"
CSV_RENAMED="${WORKDIR}/renamed_signaturen.csv"
CSV_DELETED="${WORKDIR}/deleted_old_signaturen.csv"

###############################################################################
# LOCK FILE MECHANISM & SETUP
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
# UTILITIES
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

# Unified dry-run aware command execution
exec_cmd() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        verbose_log "[DRY-RUN] would execute: $*"
        return 0
    else
        verbose_log "Executing: $*"
        "$@"
        return $?
    fi
}

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

    local count_process=0 count_manual=0 count_skipped=0 line_num=0 is_header=1

    while IFS= read -r line; do
        line_num=$((line_num + 1))
        line="${line%$'\r'}"
        IFS=';' read -ra cols <<< "$line"

        local c1="${cols[0]:-}" c2="${cols[1]:-}" c3="${cols[2]:-}"
        local c4="${cols[3]:-}" c5="${cols[4]:-}" c6="${cols[5]:-}" c7="${cols[6]:-}"

        # Skip header
        if [[ $is_header -eq 1 ]]; then
            if [[ "$c1" =~ ^[Aa]rchitekturzeichnung$ ]] || [[ "$c1" =~ ^[Cc]olumn ]] || [[ "$c1" =~ ^[Nn]ame ]]; then
                verbose_log "Skipping header line: $c1"
                is_header=0
                continue
            fi
            is_header=0
        fi

        # Skip empty or incomplete lines
        if [[ -z "$c1" || -z "$c4" || -z "$c5" ]]; then
            count_skipped=$((count_skipped + 1))
            continue
        fi

        verbose_log "Line $line_num: c1='$c1', c4='$c4', c5='$c5'"

        # Manual review cases
        if [[ -n "$c6" || -n "$c7" ]]; then
            echo "$c1;$c4;$c5;extra description present" >> "$CSV_MANUAL"
            count_manual=$((count_manual + 1))
            continue
        fi

        if [[ "$c4" != Karten* || "$c5" != Karten* ]]; then
            echo "$c1;$c4;$c5;different Bestand (not Karten)" >> "$CSV_MANUAL"
            count_manual=$((count_manual + 1))
            continue
        fi

        # Normalize and add to process list
        old_norm=$(normalize_signature "$c4")
        new_norm=$(normalize_signature "$c5")
        echo "$c1;$old_norm;$new_norm" >> "$CSV_PROCESS"
        count_process=$((count_process + 1))
        verbose_log "To process: $c1 | $old_norm -> $new_norm"

    done < "$CSV_INPUT"

    progress "CSV transformation finished: $count_process to process, $count_manual manual, $count_skipped skipped"
    log SUCCESS "CSV transformation: $count_process to process, $count_manual manual, $count_skipped skipped"
}

###############################################################################
# PROCESS 2: PATH VALIDATION
###############################################################################

process_validate_paths() {
    progress "Process 2: Path validation"

    local tmp="${CSV_PROCESS}.tmp"
    cp "$CSV_PROCESS" "$tmp"
    local count_valid=0 count_invalid=0

    while IFS=';' read -r a o n || [[ -n "${a:-}" ]]; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        local invalid=0

        # Check all required paths
        if [[ ! -d "${NETAPP_ARCH}/${a}" ]]; then
            echo "$a;$o;$n;architekturzeichnung not found" >> "$CSV_MANUAL"
            invalid=1
        elif [[ ! -d "${CEPH_KARTEN}/${o}" ]]; then
            echo "$a;$o;$n;old_path not found in cepheus" >> "$CSV_MANUAL"
            invalid=1
        elif [[ ! -d "${NETAPP_KARTEN}/${o}" ]]; then
            echo "$a;$o;$n;old_path not found in netapp" >> "$CSV_MANUAL"
            invalid=1
        elif [[ -d "${CEPH_KARTEN}/${n}" || -d "${NETAPP_KARTEN}/${n}" ]]; then
            echo "$a;$o;$n;new_path already exists" >> "$CSV_MANUAL"
            invalid=1
        fi

        if [[ $invalid -eq 1 ]]; then
            count_invalid=$((count_invalid + 1))
            grep -v "^${a};" "$tmp" > "${tmp}.filtered" 2>/dev/null && mv "${tmp}.filtered" "$tmp"
        else
            count_valid=$((count_valid + 1))
        fi

    done < "$CSV_PROCESS"

    mv "$tmp" "$CSV_PROCESS"
    progress "Path validation finished: $count_valid valid, $count_invalid invalid"
    log SUCCESS "Path validation: $count_valid valid, $count_invalid invalid"
}

###############################################################################
# PROCESS 3: CREATE NEW DIRECTORIES
###############################################################################

process_create_dirs() {
    progress "Process 3: Create new directories"

    local tmp="${CSV_PROCESS}.tmp"
    cp "$CSV_PROCESS" "$tmp"
    local count_created=0 count_failed=0

    while IFS=';' read -r a o n || [[ -n "${a:-}" ]]; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        local failed=0

        if ! exec_cmd mkdir -p "${CEPH_KARTEN}/${n}"; then
            [[ "$DRY_RUN" -eq 0 ]] && { echo "$a;$o;$n;cannot create cepheus dir" >> "$CSV_MANUAL"; failed=1; count_failed=$((count_failed + 1)); }
        fi

        if [[ $failed -eq 0 ]] && ! exec_cmd mkdir -p "${NETAPP_KARTEN}/${n}/thumbs"; then
            [[ "$DRY_RUN" -eq 0 ]] && { echo "$a;$o;$n;cannot create netapp dir" >> "$CSV_MANUAL"; failed=1; count_failed=$((count_failed + 1)); }
        fi

        [[ $failed -eq 0 ]] && count_created=$((count_created + 1))
        [[ $failed -eq 1 ]] && grep -v "^${a};" "$tmp" > "${tmp}.filtered" 2>/dev/null && mv "${tmp}.filtered" "$tmp"

    done < "$CSV_PROCESS"

    mv "$tmp" "$CSV_PROCESS"
    progress "Directory creation finished: $count_created created, $count_failed failed"
    log SUCCESS "Directory creation: $count_created created, $count_failed failed"
}

###############################################################################
# PROCESS 4: CEPHEUS MOVE
###############################################################################

process_move_cepheus() {
    progress "Process 4: Move files in Cepheus"

    echo "old_signatur_files;new_signatur_files" > "$CSV_RENAMED"
    local count_moved=0 count_files=0

    while IFS=';' read -r a o n || [[ -n "${a:-}" ]]; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        local src_arch="${NETAPP_ARCH}/${a}"
        local src_old="${CEPH_KARTEN}/${o}"
        local dst_new="${CEPH_KARTEN}/${n}"

        verbose_log "Processing entry: a=$a, old=$o, new=$n"
        verbose_log "Source arch dir: $src_arch"
        verbose_log "Source old cepheus: $src_old"
        verbose_log "Destination cepheus: $dst_new"

        # Check if directories exist
        if [[ ! -d "$src_arch" ]]; then
            log ERROR "Directory does not exist: $src_arch"
            continue
        fi

        # Process main files (symlinks or regular files)
        shopt -s nullglob  # Prevent literal * if no match
        for f in "$src_arch"/*; do
            verbose_log "Checking: $f"
            
            [[ "$f" == */thumbs ]] && { verbose_log "Skipping thumbs directory"; continue; }
            
            if [[ ! -e "$f" ]]; then
                verbose_log "Does not exist: $f"
                continue
            fi

            count_files=$((count_files + 1))
            
            # Get basename without extension
            local basename_full="$(basename "$f")"
            local name="${basename_full%.*}"
            
            verbose_log "Processing file reference: $f (name: $name)"

            # Find matching files in old cepheus location
            local found_any=0
            for oldfile in "$src_old"/${name}.*; do
                if [[ ! -f "$oldfile" ]]; then
                    verbose_log "Not a file: $oldfile"
                    continue
                fi

                found_any=1
                verbose_log "Found matching file in cepheus: $oldfile"
                
                if exec_cmd mv "$oldfile" "$dst_new/"; then
                    echo "$oldfile;${dst_new}/$(basename "$oldfile")" >> "$CSV_RENAMED"
                    count_moved=$((count_moved + 1))
                fi
            done

            if [[ $found_any -eq 0 ]]; then
                verbose_log "No matching files found in $src_old for pattern: ${name}.*"
            fi
        done
        shopt -u nullglob

    done < "$CSV_PROCESS"

    progress "Cepheus move finished: $count_moved files moved from $count_files reference files"
    log SUCCESS "Cepheus move: $count_moved files moved"
}

###############################################################################
# PROCESS 5: NETAPP MOVE
###############################################################################

process_move_netapp() {
    progress "Process 5: Move files in NetApp"

    local count_moved=0 count_thumbs=0

    while IFS=';' read -r a o n || [[ -n "${a:-}" ]]; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        local src_arch="${NETAPP_ARCH}/${a}"
        local src_old="${NETAPP_KARTEN}/${o}"
        local dst_new="${NETAPP_KARTEN}/${n}"

        verbose_log "Processing entry: a=$a, old=$o, new=$n"
        verbose_log "Source arch dir: $src_arch"
        verbose_log "Source old netapp: $src_old"
        verbose_log "Destination netapp: $dst_new"

        # Check if directories exist
        if [[ ! -d "$src_arch" ]]; then
            log ERROR "Directory does not exist: $src_arch"
            continue
        fi

        # Process main files (symlinks or regular files)
        shopt -s nullglob
        for f in "$src_arch"/*; do
            verbose_log "Checking: $f"
            
            [[ "$f" == */thumbs ]] && { verbose_log "Skipping thumbs directory"; continue; }
            
            if [[ ! -e "$f" ]]; then
                verbose_log "Does not exist: $f"
                continue
            fi

            # Get basename without extension
            local basename_full="$(basename "$f")"
            local name="${basename_full%.*}"
            
            verbose_log "Processing file reference: $f (name: $name)"

            # Move main files from old netapp location
            local found_main=0
            for oldfile in "$src_old"/${name}.*; do
                if [[ ! -f "$oldfile" ]]; then
                    verbose_log "Not a file: $oldfile"
                    continue
                fi
                found_main=1
                verbose_log "Found matching file in netapp: $oldfile"
                exec_cmd mv "$oldfile" "$dst_new/" 2>/dev/null && count_moved=$((count_moved + 1))
            done

            if [[ $found_main -eq 0 ]]; then
                verbose_log "No matching main files found in $src_old for pattern: ${name}.*"
            fi

            # Move thumbnails from old netapp thumbs location
            if [[ -d "$src_old/thumbs" ]]; then
                local found_thumbs=0
                for thumbfile in "$src_old"/thumbs/${name}.*; do
                    if [[ ! -f "$thumbfile" ]]; then
                        verbose_log "Not a thumb file: $thumbfile"
                        continue
                    fi
                    found_thumbs=1
                    verbose_log "Found matching thumb in netapp: $thumbfile"
                    exec_cmd mv "$thumbfile" "$dst_new/thumbs/" 2>/dev/null && count_thumbs=$((count_thumbs + 1))
                done

                if [[ $found_thumbs -eq 0 ]]; then
                    verbose_log "No matching thumb files found in $src_old/thumbs for pattern: ${name}.*"
                fi
            else
                verbose_log "Thumbs directory does not exist: $src_old/thumbs"
            fi
        done
        shopt -u nullglob

    done < "$CSV_PROCESS"

    progress "NetApp move finished: $count_moved files, $count_thumbs thumbs moved"
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
            if [[ -d "$p" ]]; then
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    verbose_log "[DRY-RUN] would check and possibly delete: $p"
                    count_deleted=$((count_deleted + 1))
                else
                    if [[ -z "$(ls -A "$p" 2>/dev/null)" ]]; then
                        if rmdir "$p" 2>/dev/null; then
                            echo "$p" >> "$CSV_DELETED"
                            count_deleted=$((count_deleted + 1))
                            verbose_log "Deleted empty dir: $p"
                        fi
                    fi
                fi
            fi
        done

    done < "$CSV_PROCESS"

    progress "Cleanup finished: $count_deleted directories removed"
    log SUCCESS "Cleanup: $count_deleted directories removed"
}

###############################################################################
# PROCESS 7: RECREATE SYMLINKS
###############################################################################

process_symlinks() {
    progress "Process 7: Recreate symlinks"

    local count_links=0 count_removed=0

    while IFS=';' read -r a _ n; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        local target="${NETAPP_KARTEN}/${n}"
        local linkdir="${NETAPP_ARCH}/${a}"

        # Remove old symlinks
        for old_link in "$linkdir"/* "$linkdir"/thumbs/*; do
            if [[ -L "$old_link" ]]; then
                exec_cmd rm -f "$old_link" 2>/dev/null && count_removed=$((count_removed + 1))
            fi
        done

        if [[ "$DRY_RUN" -eq 0 ]]; then
            # Create new symlinks for main files
            for f in "$target"/*; do
                [[ ! -f "$f" ]] && continue
                ln -s "${NETAPP_KARTEN}/${n}/$(basename "$f")" "$linkdir/$(basename "$f")" 2>/dev/null && count_links=$((count_links + 1))
            done

            # Create new symlinks for thumbnails
            for f in "$target/thumbs"/*; do
                [[ ! -f "$f" ]] && continue
                ln -s "${NETAPP_KARTEN}/${n}/thumbs/$(basename "$f")" "$linkdir/thumbs/$(basename "$f")" 2>/dev/null && count_links=$((count_links + 1))
            done
        fi

    done < "$CSV_PROCESS"

    progress "Symlink recreation finished: $count_removed removed, $count_links created"
    log SUCCESS "Symlink recreation: $count_removed removed, $count_links created"
}

###############################################################################
# PROCESS 8: CHECKSUM (PLACEHOLDER)
###############################################################################

process_checksum() {
    progress "Process 8: Checksum update - to be implemented"
    log INFO "Checksum update will be implemented later"
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
    log INFO "Script started - CSV Input: $CSV_INPUT"

    [[ "$DRY_RUN" -eq 1 ]] && progress "DRY-RUN MODE - No filesystem changes will be made"
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

    # Summary
    local proc_count manual_count renamed_count deleted_count
    proc_count=$(wc -l < "$CSV_PROCESS" 2>/dev/null || echo "0")
    manual_count=$(wc -l < "$CSV_MANUAL" 2>/dev/null || echo "0")
    renamed_count=$(wc -l < "$CSV_RENAMED" 2>/dev/null || echo "0")
    deleted_count=$(wc -l < "$CSV_DELETED" 2>/dev/null || echo "0")

    progress ""
    progress "========================================"
    progress "All processes finished successfully"
    progress "========================================"
    progress ""
    progress "Results location: $WORKDIR"
    progress ""
    progress "Summary:"
    progress "  - Entries processed: $((proc_count - 1))"
    progress "  - Manual review: $((manual_count - 1))"
    progress "  - Files renamed: $((renamed_count - 1))"
    progress "  - Dirs deleted: $((deleted_count - 1))"

    [[ "$DRY_RUN" -eq 1 ]] && {
        progress ""
        progress "========================================"
        progress "This was a DRY-RUN. No changes were made."
        progress "Remove the -n flag to execute operations."
        progress "========================================"
    }

    log SUCCESS "Script completed successfully"
}

main
exit 0