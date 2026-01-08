#!/usr/bin/env bash

###############################################################################
# Script Name: hstam_architekturzeichnungen_restructure.sh
# Version: 2.1
# Author: Mustafa Demiroglu
# Organisation: HlaDigiTeam
#
# Purpose:
#   Controlled restructuring of HStAM architectural drawings and Karten
#
# Notes:
#   - Manual check cases are separated
#   - Fixed CSV parsing for correct column reading
#   - Added timestamp-based workdir to prevent conflicts
###############################################################################

set -euo pipefail

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
ARCH_ZEICH="${NETAPP_ROOT}/architekturzeichnungen"
ARCH_KARTEN="${NETAPP_ROOT}/karten"

CEPH_ROOT="/media/cepheus/hstam"
CEPH_KARTEN="${CEPH_ROOT}/karten"

WORKDIR="/tmp/hstam_arch_process_$(date '+%Y%m%d_%H%M%S')"
LOGFILE="${WORKDIR}/process.log"

CSV_PROCESS="${WORKDIR}/csv_to_be_processed.csv"
CSV_MANUAL="${WORKDIR}/csv_check_manuel.csv"
CSV_RENAMED="${WORKDIR}/renamed_signaturen.csv"
CSV_DELETED="${WORKDIR}/deleted_old_signaturen.csv"

mkdir -p "$WORKDIR"

###############################################################################
# LOGGING
###############################################################################
log() {
    local level="$1"; shift
    echo "$(date '+%F %T') [$level] $*" >> "$LOGFILE"
    [[ "$VERBOSE" -eq 1 ]] && echo "[$level] $*"
}

progress() {
    echo "→ $1"
}

###############################################################################
# SAFE FS OPS (DRY-RUN WRAPPER)
###############################################################################
fs() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
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
    local line_num=0

    while IFS=';' read -r c1 c2 c3 c4 c5 c6 c7 rest; do
        line_num=$((line_num + 1))
        
        # Clean Windows line endings
        c1="${c1%$'\r'}"; c4="${c4%$'\r'}"; c5="${c5%$'\r'}"
        c6="${c6%$'\r'}"; c7="${c7%$'\r'}"
        
        # Skip empty lines or header-like lines
        [[ -z "$c1" ]] && continue
        
        # Check if c4 (old_signatur) is filled
        if [[ -z "$c4" ]]; then
            [[ "$VERBOSE" -eq 1 ]] && echo "Line $line_num: Skipping - c4 (old_signatur) empty"
            continue
        fi
        
        # If c5 is empty, no change needed -> skip
        if [[ -z "$c5" ]]; then
            [[ "$VERBOSE" -eq 1 ]] && echo "Line $line_num: Skipping - c5 (new_signatur) empty, no change needed"
            continue
        fi

        # Debug output
        if [[ "$VERBOSE" -eq 1 ]]; then
            echo "Line $line_num: c1=$c1, c4=$c4, c5=$c5, c6=${c6:-(empty)}, c7=${c7:-(empty)}"
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

    progress "CSV transformation finished: $count_process to process, $count_manual for manual review"
    log SUCCESS "CSV transformation finished: $count_process to process, $count_manual manual"
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

    while IFS=';' read -r a o n; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        if [[ ! -d "${ARCH_ZEICH}/${a}" ]]; then
            echo "$a;$o;$n;architekturzeichnung not found" >> "$CSV_MANUAL"
            sed -i "\|^$a;|d" "$tmp"
            count_invalid=$((count_invalid + 1))
            log WARN "Invalid: $a - architekturzeichnung not found"
            continue
        fi

        if [[ ! -d "${CEPH_KARTEN}/${o}" ]]; then
            echo "$a;$o;$n;old_path not found in cepheus" >> "$CSV_MANUAL"
            sed -i "\|^$a;|d" "$tmp"
            count_invalid=$((count_invalid + 1))
            log WARN "Invalid: $a - old_path not found in cepheus: $o"
            continue
        fi

        if [[ ! -d "${ARCH_KARTEN}/${o}" ]]; then
            echo "$a;$o;$n;old_path not found in netapp" >> "$CSV_MANUAL"
            sed -i "\|^$a;|d" "$tmp"
            count_invalid=$((count_invalid + 1))
            log WARN "Invalid: $a - old_path not found in netapp: $o"
            continue
        fi

        if [[ -d "${CEPH_KARTEN}/${n}" || -d "${ARCH_KARTEN}/${n}" ]]; then
            echo "$a;$o;$n;new_path already exists" >> "$CSV_MANUAL"
            sed -i "\|^$a;|d" "$tmp"
            count_invalid=$((count_invalid + 1))
            log WARN "Invalid: $a - new_path already exists: $n"
            continue
        fi
        
        count_valid=$((count_valid + 1))
    done < "$CSV_PROCESS"

    mv "$tmp" "$CSV_PROCESS"
    progress "Path validation finished: $count_valid valid, $count_invalid invalid"
    log SUCCESS "Path validation finished: $count_valid valid, $count_invalid invalid"
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

    while IFS=';' read -r a o n; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        if fs mkdir -p "${CEPH_KARTEN}/${n}"; then
            log INFO "Created cepheus dir: ${CEPH_KARTEN}/${n}"
        else
            echo "$a;$o;$n;cannot create cepheus dir" >> "$CSV_MANUAL"
            sed -i "\|^$a;|d" "$tmp"
            count_failed=$((count_failed + 1))
            log ERROR "Failed to create cepheus dir: ${CEPH_KARTEN}/${n}"
            continue
        fi

        if fs mkdir -p "${ARCH_KARTEN}/${n}/thumbs"; then
            log INFO "Created netapp dir: ${ARCH_KARTEN}/${n}/thumbs"
            count_created=$((count_created + 1))
        else
            echo "$a;$o;$n;cannot create netapp dir" >> "$CSV_MANUAL"
            sed -i "\|^$a;|d" "$tmp"
            count_failed=$((count_failed + 1))
            log ERROR "Failed to create netapp dir: ${ARCH_KARTEN}/${n}"
        fi
    done < "$CSV_PROCESS"

    mv "$tmp" "$CSV_PROCESS"
    progress "Directory creation finished: $count_created created, $count_failed failed"
    log SUCCESS "Directory creation finished: $count_created created, $count_failed failed"
}

###############################################################################
# PROCESS 4: CEPHEUS MOVE
###############################################################################
process_move_cepheus() {
    progress "Process 4: Move files in Cepheus"
    echo "old_signatur_files;new_signatur_files" > "$CSV_RENAMED"
    
    local count_moved=0

    while IFS=';' read -r a o n; do
        [[ "$a" == "architekturzeichnung" ]] && continue
        src_arch="${ARCH_ZEICH}/${a}"
        src_old="${CEPH_KARTEN}/${o}"
        dst_new="${CEPH_KARTEN}/${n}"

        for f in "$src_arch"/*; do
            [[ "$f" == */thumbs* ]] && continue
            [[ ! -f "$f" ]] && continue
            
            name="$(basename "${f%.*}")"
            for oldfile in "$src_old"/"$name".*; do
                [[ -f "$oldfile" ]] || continue
                fs mv "$oldfile" "$dst_new/"
                echo "$oldfile;${dst_new}/$(basename "$oldfile")" >> "$CSV_RENAMED"
                count_moved=$((count_moved + 1))
                log INFO "Moved in cepheus: $oldfile -> $dst_new/"
            done
        done
    done < "$CSV_PROCESS"
    
    progress "Cepheus move finished: $count_moved files moved"
    log SUCCESS "Cepheus move finished: $count_moved files moved"
}

###############################################################################
# PROCESS 5: NETAPP MOVE
###############################################################################
process_move_netapp() {
    progress "Process 5: Move files in NetApp"
    
    local count_moved=0

    while IFS=';' read -r a o n; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        src_arch="${ARCH_ZEICH}/${a}"
        src_old="${ARCH_KARTEN}/${o}"
        dst_new="${ARCH_KARTEN}/${n}"

        for f in "$src_arch"/*; do
            [[ "$f" == */thumbs* ]] && continue
            [[ ! -f "$f" ]] && continue
            
            name="$(basename "${f%.*}")"

            if fs mv "$src_old"/"$name".* "$dst_new/" 2>/dev/null; then
                count_moved=$((count_moved + 1))
                log INFO "Moved in netapp: $src_old/$name.* -> $dst_new/"
            fi
            
            if fs mv "$src_old"/thumbs/"$name".* "$dst_new/thumbs/" 2>/dev/null; then
                log INFO "Moved thumb in netapp: $src_old/thumbs/$name.* -> $dst_new/thumbs/"
            fi
        done
    done < "$CSV_PROCESS"

    progress "NetApp move finished: $count_moved files moved"
    log SUCCESS "NetApp move finished: $count_moved files moved"
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
        
        for p in "${CEPH_KARTEN}/${o}" "${ARCH_KARTEN}/${o}"; do
            if [[ -d "$p" && -z "$(ls -A "$p" 2>/dev/null)" ]]; then
                fs rmdir "$p"
                echo "$p" >> "$CSV_DELETED"
                count_deleted=$((count_deleted + 1))
                log INFO "Deleted empty dir: $p"
            fi
        done
    done < "$CSV_PROCESS"

    progress "Cleanup finished: $count_deleted directories removed"
    log SUCCESS "Cleanup finished: $count_deleted directories removed"
}


###############################################################################
# PROCESS 7: RECREATE SYMLINKS
###############################################################################
process_symlinks() {
    progress "Process 7: Recreate symlinks"
    
    local count_links=0

    while IFS=';' read -r a _ n; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        target="${ARCH_KARTEN}/${n}"
        linkdir="${ARCH_ZEICH}/${a}"

        fs rm -f "$linkdir"/* "$linkdir/thumbs"/* 2>/dev/null || true

        for f in "$target"/*; do
            [[ -f "$f" ]] || continue
            fs ln -s "/archive/www/hstam/karten/${n}/$(basename "$f")" "$linkdir/$(basename "$f")"
            count_links=$((count_links + 1))
        done

        for f in "$target/thumbs"/*; do
            [[ -f "$f" ]] || continue
            fs ln -s "/archive/www/hstam/karten/${n}/thumbs/$(basename "$f")" "$linkdir/thumbs/$(basename "$f")"
            count_links=$((count_links + 1))
        done
        
        log INFO "Recreated symlinks for: $a"
    done < "$CSV_PROCESS"

    progress "Symlink recreation finished: $count_links symlinks created"
    log SUCCESS "Symlink recreation finished: $count_links symlinks created"
}

###############################################################################
# PROCESS 8: CHECKSUM (PLACEHOLDER)
###############################################################################
process_checksum() {
    progress "Process 8: Checksum update"
    log INFO "Checksum update will be implemented later"
}


###############################################################################
# MAIN
###############################################################################
progress "Starting HStAM archive restructuring"
progress "Working directory: $WORKDIR"
log INFO "Script started"
log INFO "CSV Input: $CSV_INPUT"
log INFO "Working directory: $WORKDIR"
[[ "$DRY_RUN" -eq 1 ]] && log INFO "DRY-RUN enabled - no filesystem changes will be made"

process_csv_transform
process_validate_paths
process_create_dirs
process_move_cepheus
process_move_netapp
process_cleanup_dirs
process_symlinks
process_checksum

progress "All processes finished"
progress "Check results in: $WORKDIR"
progress "  - Processing list: $CSV_PROCESS"
progress "  - Manual review: $CSV_MANUAL"
progress "  - Renamed files: $CSV_RENAMED"
progress "  - Deleted dirs: $CSV_DELETED"
progress "  - Log file: $LOGFILE"
log SUCCESS "Script completed successfully"