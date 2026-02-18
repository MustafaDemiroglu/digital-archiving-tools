#!/usr/bin/env bash
###############################################################################
# Script Name: hstam_architekturzeichnungen_restructure.sh
# Version: 5.2.0
# Author: Mustafa Demiroglu
# Organisation: HlaDigiTeam
#
# VERY IMPORTANT:
#   This script MUST be run on the kitodo VM. If you need to run it on a different VM,
#   you MUST update the root paths in the PATH CONFIG section below.
#   Please run recreate_symlinks.sh on digiserver VM to recreate symlinks.
#
# Purpose:
#   This script reorganizes HStAM architectural drawings and map collections (mostly in Karten) 
#   by renaming signature directories and moving files between old and new directory structures.
#   It processes a CSV file containing old and new signature paths, validates all paths, creates 
#   new directory structures, moves files between storage systems (Cepheus and 
#   NetApp), recreates symlinks, and cleans up empty directories .
#	It handles both Cepheus (long-term storage) and NetApp (access storage) 
#   locations while maintaining symlinks for the architekturzeichnungen.
#
#   The script supports heterogeneous data states:
#   - signature folders with reference files in architekturzeichnungen
#   - newly created or empty architekturzeichnung folders (thumbs-only or empty)
#
#   All operations are designed to be fully dry-run safe.
#
# Core logic:
#   - Architekturzeichnung folders are considered "empty" if they contain
#     no files except a thumbs directory.
#   - If reference files exist, file moves are matched by basename.
#   - If no reference files exist, files containing the new signature are used.
#   - Files with name mismatches or missing references are logged as suspicious.
#
# How it works:
#   1. Reads a CSV file with old and new signature names
#   2. Validates all paths and directories exist and prepares target structures
#   3. Creates new directory structure in both Cepheus and NetApp
#   4. Moves files from old to new locations in Cepheus storage
#   5. Moves files and thumbnails in NetApp storage
#   6. Generates a preview.jpg per target signature by:
#      - selecting the first natural-sorted image file
#      - generating a 100x100 px JPEG preview (96 DPI, 24-bit)
#      - storing it under the thumbs directory
#   7. Logs renamed and suspicious file operations into dedicated CSV files
#   8. Removes empty old directories after successful migration under Cepheus
#   9. Recreates symlinks from architekturzeichnungen to point to new locations (check note)
#   10. Updates checksums (placeholder for future implementation)
#   11. Cleans up the renamed_signaturen.csv file paths by removing path prefix
#
# Output & Logging:
#   - renamed_signaturen.csv: successfully moved files
#   - suspect_file_moves.csv: files with missing references or name mismatches
#   - detailed logging via INFO / ERROR / SUCCESS levels
#
# Usage:
#   ./hstam_architekturzeichnungen_restructure.sh [-v] [-n] input.csv
#
# Options:
#   -v  Verbose mode: prints detailed runtime output in terminal
#   -n  Dry-run mode: simulates all operations without filesystem changes
#
# Notes:
#   - In dry-run mode, no directories or files are created, moved or modified.
#   - mkdir, mv, rsync and image generation are all guarded by exec_cmd.
#   - The script follows a strict pipeline model; each process depends on
#     the successful completion of the previous one.
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
  
Please run recreate_symlinks.sh on digiserver VM to recreate symlinks.
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
CSV_SUSPECT_FILES="${WORKDIR}/suspect_file_moves.csv"

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
        log INFO "[DRY-RUN] would execute: $*"
        if [[ "$VERBOSE" -eq 1 ]]; then
            echo "[DRY-RUN] would execute: $*"
        fi
        return 0
    else
        log INFO "Executing: $*"
        if [[ "$VERBOSE" -eq 1 ]]; then
            echo "Executing: $*"
        fi
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
# Normalize folder reference to file pattern
# Example:
#   p_ii_7496--1   → p_ii_7496_001
#   p_ii_7497--8r  → p_ii_7497_008r
###############################################################################
normalize_reference_pattern() {
    local folder_name="$1"
    folder_name="$(basename "$folder_name")"

    local pattern="${folder_name/--/_}"

    if [[ "$pattern" =~ ^(.*_)([0-9]+)([a-z]?)$ ]]; then
        local prefix="${BASH_REMATCH[1]}"
        local num="${BASH_REMATCH[2]}"
        local suffix="${BASH_REMATCH[3]}"
        printf -v num "%03d" "$num"
        pattern="${prefix}${num}${suffix}"
    fi

    echo "$pattern"
}

###############################################################################
# Check if file matches folder architecture reference
###############################################################################
file_matches_reference() {
    local file="$1"
    local folder="$2"

    local expected
    expected="$(normalize_reference_pattern "$folder")"

    [[ "$(basename "$file")" == *"$expected"* ]]
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
                log INFO "Skipping header line: $c1"
                if [[ "$VERBOSE" -eq 1 ]]; then
                    echo "Skipping header line: $c1"
                fi
                is_header=0
                continue
            fi
            is_header=0
        fi

        # Skip empty or incomplete lines
        if [[ -z "$c1" || -z "$c4" || -z "$c5" ]]; then
            count_skipped=$((count_skipped + 1))
            log INFO "Skipped incomplete line $line_num"
            continue
        fi

        log INFO "Line $line_num: c1='$c1', c4='$c4', c5='$c5'"
        if [[ "$VERBOSE" -eq 1 ]]; then
            echo "Line $line_num: c1='$c1', c4='$c4', c5='$c5'"
        fi

        # Manual review cases
        if [[ -n "$c6" || -n "$c7" ]]; then
            echo "$c1;$c4;$c5;extra description present" >> "$CSV_MANUAL"
            count_manual=$((count_manual + 1))
            log INFO "Manual review: $c1 (extra description present)"
            continue
        fi

        if [[ "$c4" != Karten* || "$c5" != Karten* ]]; then
            echo "$c1;$c4;$c5;different Bestand (not Karten)" >> "$CSV_MANUAL"
            count_manual=$((count_manual + 1))
            log INFO "Manual review: $c1 (different Bestand)"
            continue
        fi

        # Normalize and add to process list
        old_norm=$(normalize_signature "$c4")
        new_norm=$(normalize_signature "$c5")
        echo "$c1;$old_norm;$new_norm" >> "$CSV_PROCESS"
        count_process=$((count_process + 1))
        log INFO "To process: $c1 | $old_norm -> $new_norm"
        if [[ "$VERBOSE" -eq 1 ]]; then
            echo "To process: $c1 | $old_norm -> $new_norm"
        fi

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
        if [[ ! -d "${CEPH_KARTEN}/${o}" ]]; then
            echo "$a;$o;$n;old_path not found in cepheus" >> "$CSV_MANUAL"
            invalid=1
            log WARN "Invalid: $a - old_path not found in cepheus"
        elif [[ ! -d "${NETAPP_KARTEN}/${o}" ]]; then
            echo "$a;$o;$n;old_path not found in netapp" >> "$CSV_MANUAL"
            invalid=1
            log WARN "Invalid: $a - old_path not found in netapp"
        elif [[ -d "${CEPH_KARTEN}/${n}" || -d "${NETAPP_KARTEN}/${n}" ]]; then
            echo "$a;$o;$n;new_path already exists" >> "$CSV_MANUAL"
            invalid=1
            log WARN "Invalid: $a - new_path already exists"
        fi

        if [[ $invalid -eq 1 ]]; then
            count_invalid=$((count_invalid + 1))
            grep -v "^${a};" "$tmp" > "${tmp}.filtered" 2>/dev/null && mv "${tmp}.filtered" "$tmp"
        else
            count_valid=$((count_valid + 1))
            log INFO "Valid: $a | $o -> $n"
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
            [[ "$DRY_RUN" -eq 0 ]] && { 
                echo "$a;$o;$n;cannot create cepheus dir" >> "$CSV_MANUAL"
                log ERROR "Failed to create cepheus dir: ${CEPH_KARTEN}/${n}"
                failed=1
                count_failed=$((count_failed + 1))
            }
        fi

        if [[ $failed -eq 0 ]] && ! exec_cmd mkdir -p "${NETAPP_KARTEN}/${n}/thumbs"; then
            [[ "$DRY_RUN" -eq 0 ]] && { 
                echo "$a;$o;$n;cannot create netapp dir" >> "$CSV_MANUAL"
                log ERROR "Failed to create netapp dir: ${NETAPP_KARTEN}/${n}/thumbs"
                failed=1
                count_failed=$((count_failed + 1))
            }
        fi
		
		if [[ ! -d "${NETAPP_ARCH}/${a}" ]]; then
            if [[ $failed -eq 0 ]] && ! exec_cmd mkdir -p "${NETAPP_ARCH}/${a}/thumbs"; then
				[[ "$DRY_RUN" -eq 0 ]] && { 
					echo "$a;$o;$n;cannot create architekturzeichnung dir" >> "$CSV_MANUAL"
					log ERROR "Failed to create architekturzeichnung dir: ${NETAPP_ARCH}/${a}/thumbs"
					failed=1
					count_failed=$((count_failed + 1))
				}
			fi
		fi

        if [[ $failed -eq 0 ]]; then
            count_created=$((count_created + 1))
            log INFO "Created directories for: $a -> $n"
        fi
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
	echo "reason;source_file;target_dir" > "$CSV_SUSPECT_FILES"
    local count_moved=0 count_files=0

    while IFS=';' read -r a o n || [[ -n "${a:-}" ]]; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        local src_arch="${NETAPP_ARCH}/${a}"
        local src_old="${CEPH_KARTEN}/${o}"
        local dst_new="${CEPH_KARTEN}/${n}"
		local arch_has_files=0
		
		shopt -s nullglob
        for f in "$src_arch"/*; do
            [[ "$f" == */thumbs ]] && continue
            [[ -f "$f" || -L "$f" ]] && arch_has_files=1 && break
        done
        shopt -u nullglob
		
        # CASE 1: Architekturzeichnung existiert, there are files in it 
		if [[ "$arch_has_files" -eq 1 ]]; then
			shopt -s nullglob
			for f in "$src_arch"/*; do
				[[ "$f" == */thumbs ]] && continue
				[[ ! -L "$f" && ! -f "$f" ]] && continue

				count_files=$((count_files + 1))
				local basename_full="$(basename "$f")"
				local name="${basename_full%.*}"

				for oldfile in "$src_old"/${name}.*; do
					[[ ! -f "$oldfile" ]] && continue
					
					if exec_cmd mv "$oldfile" "$dst_new/"; then
						echo "$oldfile;${dst_new}/$(basename "$oldfile")" >> "$CSV_RENAMED"
						count_moved=$((count_moved + 1))
						log INFO "Moved: $oldfile -> $dst_new/"
						
						if [[ "$VERBOSE" -eq 1 ]]; then
							echo "Moved: $oldfile -> $dst_new/"
						fi
						
						if ! file_matches_reference "$oldfile" "$dst_new"; then
                            echo "name_mismatch;$oldfile;$dst_new" >> "$CSV_SUSPECT_FILES"
                        fi
					fi
				done
			done
			shopt -u nullglob
		        
		# CASE 2: Architekturzeichnung folder ist empty
		else
			shopt -s nullglob
            for oldfile in "$src_old"/*; do
                [[ ! -f "$oldfile" ]] && continue	
				if file_matches_reference "$oldfile" "$dst_new"; then
					if exec_cmd mv "$oldfile" "$dst_new/"; then
						echo "$oldfile;${dst_new}/$(basename "$oldfile")" >> "$CSV_RENAMED"
						echo "no_arch_reference;$oldfile;$dst_new" >> "$CSV_SUSPECT_FILES"
						count_moved=$((count_moved + 1))
					fi
				fi	
            done
            shopt -u nullglob
		fi	

    done < "$CSV_PROCESS"

    progress "Cepheus move finished: $count_moved files moved from $count_files reference files"
    log SUCCESS "Cepheus move: $count_moved files moved"
}

###############################################################################
# PROCESS 5: NETAPP MOVE
###############################################################################

process_move_netapp() {
    progress "Process 5: Move files in NetApp"

    local count_moved=0 count_thumbs=0 count_preview=0

    while IFS=';' read -r a o n || [[ -n "${a:-}" ]]; do
        [[ "$a" == "architekturzeichnung" ]] && continue

        local src_arch="${NETAPP_ARCH}/${a}"
        local src_old="${NETAPP_KARTEN}/${o}"
        local dst_new="${NETAPP_KARTEN}/${n}"
		local arch_has_files=0

		shopt -s nullglob
        for f in "$src_arch"/*; do
            [[ "$f" == */thumbs ]] && continue
            [[ -f "$f" || -L "$f" ]] && arch_has_files=1 && break
        done
        shopt -u nullglob
		
		# CASE 1: Architekturzeichnung existiert
		if [[ "$arch_has_files" -eq 1 ]]; then
			shopt -s nullglob
			for f in "$src_arch"/*; do
				[[ "$f" == */thumbs ]] && continue
				[[ ! -L "$f" && ! -f "$f" ]] && continue

				local basename_full="$(basename "$f")"
				local name="${basename_full%.*}"

				# Move main files
				for oldfile in "$src_old"/${name}.*; do
					[[ ! -f "$oldfile" ]] && continue
					if exec_cmd mv "$oldfile" "$dst_new/" 2>/dev/null; then
						count_moved=$((count_moved + 1))
						log INFO "Moved: $oldfile -> $dst_new/"
						
						if [[ "$VERBOSE" -eq 1 ]]; then
							echo "Moved: $oldfile -> $dst_new/"
						fi
						
						if ! file_matches_reference "$oldfile" "$dst_new"; then
                            echo "name_mismatch;$oldfile;$dst_new" >> "$CSV_SUSPECT_FILES"
                        fi
					fi
				done

				# Move thumbnails
				if [[ -d "$src_old/thumbs" ]]; then
					for thumbfile in "$src_old"/thumbs/${name}.*; do
						[[ ! -f "$thumbfile" ]] && continue
						if exec_cmd mv "$thumbfile" "$dst_new/thumbs/" 2>/dev/null; then
							count_thumbs=$((count_thumbs + 1))
							log INFO "Moved thumb: $thumbfile -> $dst_new/thumbs/"
							
							if [[ "$VERBOSE" -eq 1 ]]; then
								echo "Moved thumb: $thumbfile -> $dst_new/thumbs/"
							fi
							
							if ! file_matches_reference "$thumbfile" "$dst_new"; then
                                echo "name_mismatch;$thumbfile;$dst_new/thumbs" >> "$CSV_SUSPECT_FILES"
                            fi
						fi
					done
				fi
			done
			shopt -u nullglob
			
		# CASE 2: Architekturzeichnung is empty
		else
			shopt -s nullglob
            for oldfile in "$src_old"/*; do
                [[ ! -f "$oldfile" ]] && continue
				if file_matches_reference "$oldfile" "$dst_new"; then
					if exec_cmd mv "$oldfile" "$dst_new/" 2>/dev/null; then
						count_moved=$((count_moved + 1))
						echo "no_arch_reference;$oldfile;$dst_new" >> "$CSV_SUSPECT_FILES"
					fi
				fi
            done

            if [[ -d "$src_old/thumbs" ]]; then
                for thumbfile in "$src_old"/thumbs/*"$n"*; do
                    [[ ! -f "$thumbfile" ]] && continue
					if file_matches_reference "$thumbfile" "$dst_new"; then
						if exec_cmd mv "$thumbfile" "$dst_new/thumbs/" 2>/dev/null; then
							count_thumbs=$((count_thumbs + 1))
							echo "no_arch_reference;$thumbfile;$dst_new/thumbs" >> "$CSV_SUSPECT_FILES"
						fi
					fi
                done
            fi
            shopt -u nullglob
        fi
				
		# Create preview.jpg from first image in destination folder
		if [[ -d "$dst_new" ]]; then
			shopt -s nullglob

			first_image=""
			for img in "$dst_new"/*.{jpg,jpeg,png,tif,tiff}; do
				first_image="$img"
				break
			done

			if [[ -n "$first_image" ]]; then
				exec_cmd mkdir -p "$dst_new/thumbs"

				if exec_cmd convert \
					"$first_image" \
					-resize 100x100^ \
					-gravity center \
					-extent 100x100 \
					-density 96x96 \
					-depth 24 \
					"$dst_new/thumbs/preview.jpg"; then

					count_preview=$((count_preview + 1))
					log INFO "Generated preview: $dst_new/thumbs/preview.jpg from $(basename "$first_image")"

					[[ "$VERBOSE" -eq 1 ]] && \
						echo "Generated preview from $(basename "$first_image")"
				fi
			fi

			shopt -u nullglob
		fi

    done < "$CSV_PROCESS"

    progress "NetApp move finished: $count_moved files, $count_thumbs thumbs moved, $count_preview preview created"
    log SUCCESS "NetApp move: $count_moved files, $count_thumbs thumbs moved, $count_preview preview created"
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

        for p in "${CEPH_KARTEN}/${o}"; do
            if [[ -d "$p" ]]; then
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    log INFO "[DRY-RUN] would check and possibly delete: $p"
                    if [[ "$VERBOSE" -eq 1 ]]; then
                        echo "[DRY-RUN] would check and possibly delete: $p"
                    fi
                    count_deleted=$((count_deleted + 1))
                else
                    # Check if directory is empty and delete
                    if [[ -z "$(ls -A "$p" 2>/dev/null)" ]]; then
                        if rmdir "$p" 2>/dev/null; then
                            echo "$p" >> "$CSV_DELETED"
                            count_deleted=$((count_deleted + 1))
                            log INFO "Deleted empty dir: $p"
                            if [[ "$VERBOSE" -eq 1 ]]; then
                                echo "Deleted empty dir: $p"
                            fi
                        fi
                    fi
                fi
            fi
        done
		
		for p in "${NETAPP_KARTEN}/${o}/thumbs" "${NETAPP_KARTEN}/${o}"; do
            if [[ -d "$p" ]]; then
                if [[ "$DRY_RUN" -eq 1 ]]; then
                    log INFO "[DRY-RUN] would check and possibly delete: $p"
                    if [[ "$VERBOSE" -eq 1 ]]; then
                        echo "[DRY-RUN] would check and possibly delete: $p"
                    fi
                    count_deleted=$((count_deleted + 1))
                else
                    # Remove preview.jpg if it's the only file in thumbs
                    if [[ "$p" == */thumbs && -f "$p/preview.jpg" ]]; then
                        local file_count=$(ls -A "$p" 2>/dev/null | wc -l)
                        if [[ "$file_count" -eq 1 ]]; then
                            if rm -f "$p/preview.jpg" 2>/dev/null; then
                                log INFO "Deleted preview.jpg from: $p"
                                if [[ "$VERBOSE" -eq 1 ]]; then
                                    echo "Deleted preview.jpg from: $p"
                                fi
                            fi
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

# NOTE: This process has been skipped because symlinks must be created on the
#       digiserver VM where the online shares are served from. 
#       Please run recreate_symlinks.sh on digiserver VM to recreate symlinks.

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
                if exec_cmd rm -f "$old_link" 2>/dev/null; then
                    count_removed=$((count_removed + 1))
                    log INFO "Removed old symlink: $old_link"
                    if [[ "$VERBOSE" -eq 1 ]]; then
                        echo "Removed old symlink: $old_link"
                    fi
                fi
            fi
        done

        # Create new symlinks for main files
        for f in "$target"/*; do
            [[ ! -f "$f" ]] && continue
            local link_target="${NETAPP_KARTEN}/${n}/$(basename "$f")"
            local link_name="$linkdir/$(basename "$f")"
            
            if [[ "$DRY_RUN" -eq 1 ]]; then
                log INFO "[DRY-RUN] would create symlink: $link_name -> $link_target"
                if [[ "$VERBOSE" -eq 1 ]]; then
                    echo "[DRY-RUN] would create symlink: $link_name -> $link_target"
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
        for f in "$target/thumbs"/*; do
            [[ ! -f "$f" ]] && continue
            local link_target="${NETAPP_KARTEN}/${n}/thumbs/$(basename "$f")"
            local link_name="$linkdir/thumbs/$(basename "$f")"
            
            if [[ "$DRY_RUN" -eq 1 ]]; then
                log INFO "[DRY-RUN] would create symlink: $link_name -> $link_target"
                if [[ "$VERBOSE" -eq 1 ]]; then
                    echo "[DRY-RUN] would create symlink: $link_name -> $link_target"
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

    done < "$CSV_PROCESS"

    progress "Symlink recreation finished: $count_removed removed, $count_links created"
    log SUCCESS "Symlink recreation: $count_removed removed, $count_links created"
}

process_symlinks_temp() {
    progress "Process 7: Recreate symlinks"
    progress "This process has been skipped because symlinks must be created on the digiserver VM where"
	progress "the online shares are served from. Please run recreate_symlinks.sh on digiserver VM to recreate symlinks."
}

###############################################################################
# PROCESS 8: CLEAN UP RENAMED CSV
###############################################################################

process_clean_renamed_csv() {
    progress "Process 8: Clean up renamed CSV paths"
    
    local tmp="${CSV_RENAMED}.tmp"
    local count_cleaned=0
    
    # Read header
    local header
    IFS= read -r header < "$CSV_RENAMED"
    echo "$header" > "$tmp"
    
    # Process each line
    while IFS=';' read -r old_path new_path || [[ -n "${old_path:-}" ]]; do
        [[ "$old_path" == "old_signatur_files" ]] && continue
        
        # Remove /media/cepheus/ from both paths
        local cleaned_old="${old_path#/media/cepheus/}"
        local cleaned_new="${new_path#/media/cepheus/}"
        
        echo "${cleaned_old};${cleaned_new}" >> "$tmp"
        count_cleaned=$((count_cleaned + 1))
        log INFO "Cleaned paths: $old_path -> $cleaned_old"
        
    done < "$CSV_RENAMED"
    
    mv "$tmp" "$CSV_RENAMED"
    
    progress "CSV path cleanup finished: $count_cleaned entries cleaned"
    log SUCCESS "CSV path cleanup: $count_cleaned entries cleaned"
}

###############################################################################
# PROCESS 9: CHECKSUM (PLACEHOLDER)
###############################################################################

process_checksum() {
    progress "Process 9: Checksum update - to be implemented"
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
    process_symlinks_temp
    process_clean_renamed_csv
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