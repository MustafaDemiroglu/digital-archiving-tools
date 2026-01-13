#!/usr/bin/env bash
###############################################################################
# Script Name: recreate_symlinks.sh
# Version: 1.1.3
# Author: Mustafa Demiroglu
# Organisation: HlaDigiTeam
#
# Purpose:
#   This script recreates symlinks HStAM architectural drawings and map collections (mostly in Karten) 
#   while maintaining symlinks for the architekturzeichnungen.
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
# PATH CONFIG
###############################################################################

DIGISERVER_ROOT="/archive/www/hstam"
DIGISERVER_ARCH="${DIGISERVER_ROOT}/architekturzeichnungen"
DIGISERVER_KARTEN="${DIGISERVER_ROOT}/karten"

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
        if [[ -d "$linkdir" ]]; then
            for old_link in "$linkdir"/*; do
                [[ ! -e "$old_link" && ! -L "$old_link" ]] && continue
                if [[ -L "$old_link" ]]; then
                    if [[ "$DRY_RUN" -eq 1 ]]; then
                        log INFO "[DRY-RUN] Would remove: $old_link"
                        if [[ "$VERBOSE" -eq 1 ]]; then
                            echo "[DRY-RUN] Would remove: $old_link"
                        fi
                        count_removed=$((count_removed + 1))
                    else
                        if rm -f "$old_link" 2>/dev/null; then
                            count_removed=$((count_removed + 1))
                            log INFO "Removed old symlink: $old_link"
                            if [[ "$VERBOSE" -eq 1 ]]; then
                                echo "Removed old symlink: $old_link"
                            fi
                        fi
                    fi
                fi
            done
        fi

        # Remove old symlinks in thumbs directory
        if [[ -d "$linkdir/thumbs" ]]; then
            for old_link in "$linkdir/thumbs"/*; do
                [[ ! -e "$old_link" && ! -L "$old_link" ]] && continue
                if [[ -L "$old_link" ]]; then
                    if [[ "$DRY_RUN" -eq 1 ]]; then
                        log INFO "[DRY-RUN] Would remove: $old_link"
                        if [[ "$VERBOSE" -eq 1 ]]; then
                            echo "[DRY-RUN] Would remove: $old_link"
                        fi
                        count_removed=$((count_removed + 1))
                    else
                        if rm -f "$old_link" 2>/dev/null; then
                            count_removed=$((count_removed + 1))
                            log INFO "Removed old symlink: $old_link"
                            if [[ "$VERBOSE" -eq 1 ]]; then
                                echo "Removed old symlink: $old_link"
                            fi
                        fi
                    fi
                fi
            done
        fi

        # Create new symlinks for main files
        for f in "$target"/*; do
            [[ ! -f "$f" ]] && continue
            local link_target="${DIGISERVER_KARTEN}/${new_sig}/$(basename "$f")"
            local link_name="$linkdir/$(basename "$f")"
            
            if [[ "$DRY_RUN" -eq 1 ]]; then
                log INFO "[DRY-RUN] Would create symlink: $link_name -> $link_target"
                if [[ "$VERBOSE" -eq 1 ]]; then
                    echo "[DRY-RUN] Would create symlink: $link_name -> $link_target"
                fi
                count_links=$((count_links + 1))
            else
                if ln -s "$link_target" "$link_name" 2>/dev/null; then
                    count_links=$((count_links + 1))
                    log INFO "Created symlink: $link_name -> $link_target"
                    if [[ "$VERBOSE" -eq 1 ]]; then
                        echo "Created symlink: $link_name -> $link_target"
                    fi
                else
                    log ERROR "Failed to create symlink: $link_name -> $link_target"
                fi
            fi
        done

        # Create new symlinks for thumbnails
        if [[ -d "$target/thumbs" ]]; then
            for f in "$target/thumbs"/*; do
                [[ ! -f "$f" ]] && continue
                local link_target="${DIGISERVER_KARTEN}/${new_sig}/thumbs/$(basename "$f")"
                local link_name="$linkdir/thumbs/$(basename "$f")"
                
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    log INFO "[DRY-RUN] Would create symlink: $link_name -> $link_target"
                    if [[ "$VERBOSE" -eq 1 ]]; then
                        echo "[DRY-RUN] Would create symlink: $link_name -> $link_target"
                    fi
                    count_links=$((count_links + 1))
                else
                    if ln -s "$link_target" "$link_name" 2>/dev/null; then
                        count_links=$((count_links + 1))
                        log INFO "Created symlink: $link_name -> $link_target"
                        if [[ "$VERBOSE" -eq 1 ]]; then
                            echo "Created symlink: $link_name -> $link_target"
                        fi
                    else
                        log ERROR "Failed to create symlink: $link_name -> $link_target"
                    fi
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