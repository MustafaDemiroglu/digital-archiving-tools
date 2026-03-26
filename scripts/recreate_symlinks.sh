#!/usr/bin/env bash
###############################################################################
# Script Name	: recreate_symlinks.sh
# Version		: 2.1.1
# Author		: Mustafa Demiroglu
# Organisation	: HlaDigiTeam
# Date			: 26.03.2026
# Licnce		: MIT
#
# IMPORTANT:
#   This script uses RELATIVE symlinks and is therefore VM-independent.
#   It can be run on any VM (kitodo, digiserver, etc.) without path changes.
#   Relative symlinks work regardless of the absolute mount prefix.
#
# Purpose:
#   This script recreates symlinks HStAM architectural drawings and map collections (mostly in Karten) 
#   while maintaining symlinks for the architekturzeichnungen.
#
# Why relative symlinks?
#   kitodo VM : /media/archive/public/www/hstam/...
#   digiserver: /archive/www/hstam/...
#   Absolute symlinks break when mount prefix differs between VMs.
#   Relative symlinks (e.g. ../../karten/Y/file.tif) are prefix-independent
#   and resolve correctly on every VM as long as the internal directory
#   structure under the hstam root remains the same.
#
# How it works:
#   1. Reads a CSV file with architekturzeichnung and new signature names  
#   2. Recreates symlinks from architekturzeichnungen to point to new locations
#
# Usage:
#   ./recreate_symlinks.sh [-v] [-n] input.csv
#   -v: Verbose mode - shows detailed output in terminal
#   -n: Dry-run mode - simulates operations without making changes
# The script recreates symlinks to maintain archive integrity.
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
# PATH CONFIG  (VM-independent auto-detection)
###############################################################################

# Auto-detect hstam root by checking both known mount points.
# Add further candidate paths here if new VMs are introduced.
HSTAM_ROOT=""
for candidate in \
    "/media/archive/public/www/hstam" \
    "/archive/www/hstam"; do
    if [[ -d "$candidate" ]]; then
        HSTAM_ROOT="$candidate"
        break
    fi
done

if [[ -z "$HSTAM_ROOT" ]]; then
    echo "ERROR: Cannot locate hstam root directory."
    echo "  Tried: /media/archive/public/www/hstam"
    echo "         /archive/www/hstam"
    echo "  Add the correct path to the candidate list in the PATH CONFIG section."
    exit 1
fi

HSTAM_ARCH="${HSTAM_ROOT}/architekturzeichnungen"
HSTAM_KARTEN="${HSTAM_ROOT}/karten"

WORKDIR="/tmp/recreate_symlinks_$(date '+%Y%m%d_%H%M%S')_$$"
LOGFILE="${WORKDIR}/process.log"

# Create working directory
mkdir -p "$WORKDIR"

###############################################################################
# HELPER FUNCTIONS
###############################################################################

log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$LOGFILE"
}

progress() {
    echo "$@"
}

exec_cmd() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log INFO "[DRY-RUN] Would execute: $*"
        return 0
    else
        "$@"
        return $?
    fi
}

###############################################################################
# RELATIVE SYMLINK HELPER
###############################################################################
# make_relative_symlink <link_path> <absolute_target>
#
# Creates a symlink at <link_path> pointing to <absolute_target> using a
# relative path.  This makes the symlink VM-independent: it resolves correctly
# regardless of the absolute mount prefix of the hstam share.
#
# Example:
#   link  : /media/archive/public/www/hstam/architekturzeichnungen/A123/file.tif
#   target: /media/archive/public/www/hstam/karten/K456/file.tif
#   stored: ../../karten/K456/file.tif   (relative from link directory)
###############################################################################

make_relative_symlink() {
    local link_path="$1"
    local abs_target="$2"

    local link_dir
    link_dir="$(dirname "$link_path")"

    # Compute the relative path from link_dir to abs_target
    local rel_target
    rel_target="$(realpath --relative-to="$link_dir" "$abs_target" 2>/dev/null)"

    # Fallback: manual relative path calculation if realpath is unavailable
    if [[ -z "$rel_target" ]]; then
        rel_target="$(_manual_relative_path "$link_dir" "$abs_target")"
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log INFO "[DRY-RUN] Would create relative symlink: $link_path -> $rel_target  (abs: $abs_target)"
        if [[ "$VERBOSE" -eq 1 ]]; then
            echo "[DRY-RUN] Would create relative symlink: $link_path -> $rel_target"
        fi
        return 0
    else
        if ln -s "$rel_target" "$link_path" 2>/dev/null; then
            log INFO "Created relative symlink: $link_path -> $rel_target"
            if [[ "$VERBOSE" -eq 1 ]]; then
                echo "Created relative symlink: $link_path -> $rel_target"
            fi
            return 0
        else
            log ERROR "Failed to create symlink: $link_path -> $rel_target"
            return 1
        fi
    fi
}

# Pure-bash fallback for computing a relative path (no external tools needed).
_manual_relative_path() {
    local from="$1"  # directory containing the symlink
    local to="$2"    # absolute target path

    # Normalise (remove trailing slashes)
    from="${from%/}"
    to="${to%/}"

    # Split into components
    IFS='/' read -ra from_parts <<< "$from"
    IFS='/' read -ra to_parts   <<< "$to"

    # Find common prefix length
    local common=0
    local max=${#from_parts[@]}
    [[ ${#to_parts[@]} -lt $max ]] && max=${#to_parts[@]}
    for (( i=0; i<max; i++ )); do
        [[ "${from_parts[$i]}" == "${to_parts[$i]}" ]] || break
        common=$((i + 1))
    done

    # Build relative path: go up from 'from' to common ancestor, then down to 'to'
    local rel=""
    local up=$(( ${#from_parts[@]} - common ))
    for (( i=0; i<up; i++ )); do rel="${rel}../"; done
    for (( i=common; i<${#to_parts[@]}; i++ )); do
        rel="${rel}${to_parts[$i]}/"
    done

    # Remove trailing slash
    echo "${rel%/}"
}

###############################################################################
# LOCK MECHANISM
###############################################################################

LOCKFILE="/tmp/hstam_arch_process.lock"

acquire_lock() {
    if [[ -f "$LOCKFILE" ]]; then
        echo "Error: Another instance is running (lock file exists: $LOCKFILE)"
        exit 1
    fi
    touch "$LOCKFILE"
    trap 'rm -f "$LOCKFILE"' EXIT
}

###############################################################################
# PROCESS: RECREATE SYMLINKS
###############################################################################

process_symlinks() {
    local count_links=0 count_removed=0
    local line_num=0

    while IFS=';' read -r arch _ new_sig; do
        line_num=$((line_num + 1))
        
        # Skip header
        [[ "$arch" == "architekturzeichnung" ]] && continue
        
        # Skip empty lines
        [[ -z "$arch" || -z "$new_sig" ]] && continue

        local target="${DIGISERVER_KARTEN}/${new_sig}"
        local linkdir="${DIGISERVER_ARCH}/${arch}"

        # Check if target directory exists
        if [[ ! -d "$target" ]]; then
            log ERROR "Target directory does not exist: $target"
            progress "ERROR: Target directory does not exist: $target"
            continue
        fi

        # Check if linkdir exists
        if [[ ! -d "$linkdir" ]]; then
            log ERROR "Link directory does not exist: $linkdir"
            progress "ERROR: Link directory does not exist: $linkdir"
            continue
        fi

        log INFO "Processing: $arch -> $new_sig"
        if [[ "$VERBOSE" -eq 1 ]]; then
            progress "Processing: $arch -> $new_sig"
        fi

        # Remove old symlinks in main directory
        for old_link in "$linkdir"/*; do
            [[ ! -e "$old_link" && ! -L "$old_link" ]] && continue
            if [[ -L "$old_link" ]]; then
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    log INFO "[DRY-RUN] Would remove: $old_link"
                    [[ "$VERBOSE" -eq 1 ]] && echo "[DRY-RUN] Would remove: $old_link"
                    count_removed=$((count_removed + 1))
                else
                    if rm -f "$old_link" 2>/dev/null; then
                        count_removed=$((count_removed + 1))
                        log INFO "Removed old symlink: $old_link"
                        [[ "$VERBOSE" -eq 1 ]] && echo "Removed old symlink: $old_link"
                    fi
                fi
            fi
        done

        # Remove old symlinks in thumbs directory
        if [[ -d "$linkdir/thumbs" ]]; then
            for old_link in "$linkdir/thumbs"/*; do
                [[ ! -e "$old_link" && ! -L "$old_link" ]] && continue
                if [[ -L "$old_link" ]]; then
                    if [[ "$DRY_RUN" -eq 1 ]]; then
                        log INFO "[DRY-RUN] Would remove: $old_link"
                        [[ "$VERBOSE" -eq 1 ]] && echo "[DRY-RUN] Would remove: $old_link"
                        count_removed=$((count_removed + 1))
                    else
                        if rm -f "$old_link" 2>/dev/null; then
                            count_removed=$((count_removed + 1))
                            log INFO "Removed old symlink: $old_link"
                            [[ "$VERBOSE" -eq 1 ]] && echo "Removed old symlink: $old_link"
                        fi
                    fi
                fi
            done
        fi

        # Create new RELATIVE symlinks for main files
        for f in "$target"/*; do
            [[ ! -f "$f" ]] && continue
            local abs_target="${HSTAM_KARTEN}/${new_sig}/$(basename "$f")"
            local link_name="$linkdir/$(basename "$f")"
            
            if make_relative_symlink "$link_name" "$abs_target"; then
                count_links=$((count_links + 1))
            fi
        done

        # Create new RELATIVE symlinks for thumbnails
        if [[ -d "$target/thumbs" ]]; then
            for f in "$target/thumbs"/*; do
                [[ ! -f "$f" ]] && continue
                local abs_target="${HSTAM_KARTEN}/${new_sig}/thumbs/$(basename "$f")"
                local link_name="$linkdir/thumbs/$(basename "$f")"
                
                if make_relative_symlink "$link_name" "$abs_target"; then
                    count_links=$((count_links + 1))
                fi
            done
        fi

    done < "$CSV_INPUT"

    progress "Symlink recreation finished: $count_removed removed, $count_links created"
    log SUCCESS "Symlink recreation: $count_removed removed, $count_links created"
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

    progress ""
    progress "Starting processing symlinks ..."
    progress ""

    process_symlinks

    progress ""
    progress "========================================"
    progress "All processes finished successfully"
    progress "========================================"
    progress ""
    progress "Results location: $WORKDIR"
    progress "Log file: $LOGFILE"
    progress ""
	
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