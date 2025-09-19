#!/bin/bash
###############################################################################
# Script Name: pdf_extract_images_parallel.sh (based on pdf_extract_images_parallel.sh v:5.8)
# Version 1.1 
# Author : Mustafa Demiroglu
#
# Description:
#   This script extracts each page from PDF files into separate images using 'pdfimages'.
#   It supports both TIFF (.tif) and JPEG (.jpg).
#   The script is designed to run on Linux, macOS, or WSL (Windows Subsystem).
#   Concurrency lock prevents multiple instances.
#
# NEW FEATURES:
#   - Parallel processing support (-p/--parallel)
#   - Help menu (-h/--help)
#   - Dry-run mode (-n/--dry-run) to preview what will be processed
#   - Verbose mode (-v/--verbose) for detailed output
#
# How it works:
#   1. If you do not provide a path, it works in the current folder and subfolders.
#   2. You can choose the output format (tif or jpg). If not provided, the script asks you.
#   3. Output images are named like: haus_bestand_nr_stück_0001.tif / 0001.jpg(based on folder hierarchy)
#      If not enough folder depth → fallback: pdfname_0001.tif
#	   If a folder contains >1 PDF, always use pdfname_0001.ext
#   4. After extraction, checks if number of images = number of PDF pages.
#      - If mismatch → cleanup images, PDF stays in place, error logged.
#      - If equal → PDF moved to "processed_pdfs".
#   5. A log file is created with results and errors.
#
# Requirements:
#   - ImageMagick (for 'pdfimages')
#   - pdfinfo (from poppler-utils package, to count PDF pages)
#   - GNU parallel (optional, for parallel processing)
#
# Example usage:
#   ./pdf_extract_images.sh                           # process PDFs in current dir
#   ./pdf_extract_images.sh /path/to/data             # process PDFs in given folder
#   ./pdf_extract_images.sh /data jpg                 # extract as jpg instead of tif
#   ./pdf_extract_images.sh -p /data jpg              # parallel processing
#   ./pdf_extract_images.sh --dry-run /data           # preview what will be processed
#   ./pdf_extract_images.sh -v -p /data jpg           # verbose parallel processing
#   ./pdf_extract_images.sh --help                    # show help
###############################################################################

set -euo pipefail

# --- Default values and global variables ---
PARALLEL_MODE=false      # Enable parallel processing
DRY_RUN=false           # Preview mode - don't actually process
VERBOSE=false           # Detailed output mode
MAX_JOBS=4              # Default number of parallel jobs

# --- Function to show help ---
show_help() {
    cat << EOF
PDF Image Extraction Script v6.0

USAGE:
    $0 [OPTIONS] [PATH] [FORMAT]

DESCRIPTION:
    Extracts pages from PDF files as individual images (TIFF or JPEG).
    Processes PDFs recursively in specified directory.

ARGUMENTS:
    PATH        Directory to process (default: current directory)
    FORMAT      Output format: 'tif', 'jpg', or 'all' (default: asks user)

OPTIONS:
    -p, --parallel      Enable parallel processing (faster for multiple PDFs)
    -j, --jobs N        Number of parallel jobs (default: 4, only with -p)
    -n, --dry-run       Preview what will be processed without actual extraction
    -v, --verbose       Show detailed progress information
    -h, --help          Show this help message

EXAMPLES:
    $0                                    # Interactive mode in current directory
    $0 /home/user/pdfs tif               # Extract as TIFF from specific path
    $0 -p -j 8 /data jpg                 # Parallel processing with 8 jobs, JPEG output
    $0 --dry-run --verbose /docs         # Preview processing with detailed output
    $0 -v -p /archive all                # Verbose parallel processing, all formats

REQUIREMENTS:
    - pdfimages (ImageMagick or poppler-utils)
    - pdfinfo (poppler-utils)
    - pdftoppm (poppler-utils)
    - GNU parallel (optional, for -p option)

EOF
}

# --- Function for verbose logging ---
verbose() {
    if [[ "$VERBOSE" == true ]]; then
        echo "$(date +"%F %T") [VERBOSE] $*" | tee -a "$LOGFILE"
    fi
}

# --- Parse command line arguments ---
parse_arguments() {
    local args=()
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                exit 0
                ;;
            -p|--parallel)
                PARALLEL_MODE=true
                verbose "Parallel mode enabled"
                shift
                ;;
            -j|--jobs)
                if [[ -n "${2:-}" && "$2" =~ ^[0-9]+$ ]]; then
                    MAX_JOBS="$2"
                    verbose "Maximum jobs set to: $MAX_JOBS"
                    shift 2
                else
                    echo "Error: --jobs requires a number" >&2
                    exit 1
                fi
                ;;
            -n|--dry-run)
                DRY_RUN=true
                verbose "Dry-run mode enabled (preview only)"
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -*)
                echo "Error: Unknown option $1" >&2
                echo "Use --help for usage information" >&2
                exit 1
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done
    
    # Set positional parameters from remaining arguments
    set -- "${args[@]}"
    
    # Original parameter parsing
    WORKDIR="${1:-$(pwd)}"
    OUTFMT="${2:-}"
    
    verbose "Work directory: $WORKDIR"
    verbose "Output format: ${OUTFMT:-not specified}"
}

# --- Check if parallel is available when needed ---
check_parallel_availability() {
    if [[ "$PARALLEL_MODE" == true ]]; then
        if ! command -v parallel >/dev/null 2>&1; then
            echo "Error: GNU parallel is required for parallel processing but not found." >&2
            echo "Install it with: apt-get install parallel (Ubuntu/Debian)" >&2
            echo "Or use: brew install parallel (macOS)" >&2
            echo "Continuing in sequential mode..." >&2
            PARALLEL_MODE=false
        else
            verbose "GNU parallel found, parallel processing available"
        fi
    fi
}

# --- Initialize script ---
initialize_script() {
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    LOGFILE="$WORKDIR/log_pdf_extract_${TIMESTAMP}.txt"
    ERRFILE="$WORKDIR/error_pdf_extract_${TIMESTAMP}.txt"
    TMPPDFDIR="processed_pdfs"
    LOCKFILE="/tmp/pdf_extract.lock"

    # Create lock file for dry-run too (to prevent multiple dry-runs)
    exec 200>"$LOCKFILE"
    flock -n 200 || { 
        echo "Another instance is running. Exiting." | tee -a "$ERRFILE"
        exit 1
    }

    # Ask for format if not provided (skip in dry-run if not specified)
    if [[ -z "$OUTFMT" && "$DRY_RUN" == false ]]; then
        read -p "Which output format do you want (tif/jpg/all)? " OUTFMT
    elif [[ -z "$OUTFMT" && "$DRY_RUN" == true ]]; then
        OUTFMT="tif"  # Default for dry-run preview
        verbose "Using default format 'tif' for dry-run preview"
    fi
    
    OUTFMT=$(echo "$OUTFMT" | tr '[:upper:]' '[:lower:]')

    if [[ "$OUTFMT" != "tif" && "$OUTFMT" != "jpg" && "$OUTFMT" != "all" ]]; then
        err "Error: output format must be 'tif' or 'jpg' or 'all'"
        exit 1
    fi

    # Prepare directories and logs (skip directory creation in dry-run)
    if [[ "$DRY_RUN" == false ]]; then
        mkdir -p "$WORKDIR/$TMPPDFDIR"
    fi
    
    : > "$LOGFILE"
    : > "$ERRFILE"
}

# --- Helper for logging ---
log() { echo "$(date +"%F %T") [INFO] $*" | tee -a "$LOGFILE"; }
warn() { echo "$(date +"%F %T") [WARN] $*" | tee -a "$ERRFILE" "$LOGFILE"; }
err() { echo "$(date +"%F %T") [ERROR] $*" | tee -a "$ERRFILE" "$LOGFILE"; }

cleanup_and_exit() {
    local rc=${1:-0}
    # Release lock
    flock -u 200 || true
    # Move logs even on error if possible (skip in dry-run)
    if [[ "$DRY_RUN" == false && -d "$WORKDIR/$TMPPDFDIR" ]]; then
        mv -f "$LOGFILE" "$WORKDIR/$TMPPDFDIR/" 2>/dev/null || true
        mv -f "$ERRFILE" "$WORKDIR/$TMPPDFDIR/" 2>/dev/null || true
    fi
    exit "$rc"
}

# Set up cleanup trap
trap 'cleanup_and_exit $?' EXIT INT TERM

# --- Process PDF function (enhanced with dry-run support) ---
process_pdf() {
    local pdf="$1"
    local base dir pages prefix temp_prefix extracted imgcount status parent curr_dirname grandparent grandparent_dir pdf_count

    base=$(basename "$pdf" .pdf)
    dir=$(dirname "$pdf")
    curr_dirname=$(basename "$dir")
    parent=$(basename "$(dirname "$dir")")
    grandparent_dir=$(dirname "$(dirname "$dir")")
    grandparent=$(basename "$grandparent_dir")

    # In dry-run mode, just show what would be processed
    if [[ "$DRY_RUN" == true ]]; then
        echo "DRY-RUN: Would process: $pdf"
        
        # Still check if we can read the PDF
        if ! pages=$(pdfinfo "$pdf" 2>/dev/null | awk '/Pages:/ {print $2}'); then
            echo "DRY-RUN: WARNING - Cannot read PDF info: $pdf"
            return 1
        fi
        
        # Build prefix from directory structure (same logic as main function)
        pdf_count=$(find "$dir" -maxdepth 1 -type f -iname "*.pdf" | wc -l)
        
        if [[ "$pdf_count" -gt 1 ]]; then
            prefix="$base"
            echo "DRY-RUN: Multiple PDFs in folder, would use PDF name as prefix: $prefix"
        else
            if [[ -n "$grandparent" && "$grandparent" != "/" && "$grandparent" != "." ]]; then
                prefix="${grandparent}_${parent}_nr_${curr_dirname}"
            else
                prefix="${base}"
            fi
        fi
        
        prefix="${prefix// /_}"
        
        echo "DRY-RUN: Output prefix would be: $prefix"
        echo "DRY-RUN: Would extract $pages pages from: $pdf"
        echo "DRY-RUN: Example output files: ${prefix}_0001.$OUTFMT, ${prefix}_0002.$OUTFMT, ..."
        echo "DRY-RUN: Would move PDF to: $WORKDIR/$TMPPDFDIR/.../$(basename "$pdf")"
        echo "DRY-RUN: ---"
        
        return 0
    fi

    # Original processing logic continues here for non-dry-run mode
    log "Processing: $pdf"
    verbose "PDF location: $pdf"
    verbose "Working directory: $dir"
    
    # Count pages
    if ! pages=$(pdfinfo "$pdf" 2>/dev/null | awk '/Pages:/ {print $2}'); then
        err "pdfinfo failed for $pdf"
        return 1
    fi
    if [[ -z "$pages" ]]; then
        err "cannot read page count for $pdf"
        return 1
    fi
    
    verbose "PDF has $pages pages"
    
    # Build prefix from directory structure
    pdf_count=$(find "$dir" -maxdepth 1 -type f -iname "*.pdf" | wc -l)
    verbose "Found $pdf_count PDFs in directory $dir"

    if [[ "$pdf_count" -gt 1 ]]; then
        prefix="$base"
        warn "Multiple PDFs in folder, using PDF name as prefix: $prefix"
        verbose "Checking for filename conflicts..."
        
        # Check for potential filename conflicts with existing file
        # Determine expected file extensions based on output format
        expected_extensions=()
        if [[ "$OUTFMT" == "tif" ]]; then expected_extensions=("tif")
        elif [[ "$OUTFMT" == "jpg" ]]; then expected_extensions=("jpg")
        else expected_extensions=("tif" "jpg" "pbm" "pgm" "ppm"); fi
        
        # Check for conflicts with existing files
        for ext in "${expected_extensions[@]}"; do
            if ls "${dir}/${prefix}_"[0-9][0-9][0-9][0-9]."${ext}" >/dev/null 2>&1; then
                err "Filename conflict detected in $pdf (found ${prefix}_NNNN.${ext})"
                return 1
            fi
        done
    else
        # Single PDF in folder - use directory structure naming
        if [[ -n "$grandparent" && "$grandparent" != "/" && "$grandparent" != "." ]]; then
            prefix="${grandparent}_${parent}_nr_${curr_dirname}"
            verbose "Using directory structure prefix: $prefix"
            
            # Check for filename conflicts in single PDF scenario
            expected_extensions=()
            if [[ "$OUTFMT" == "tif" ]]; then expected_extensions=("tif")
            elif [[ "$OUTFMT" == "jpg" ]]; then expected_extensions=("jpg")
            else expected_extensions=("tif" "jpg" "pbm" "pgm" "ppm"); fi
            
            for ext in "${expected_extensions[@]}"; do
                if ls "${dir}/${prefix}_"[0-9][0-9][0-9][0-9]."${ext}" >/dev/null 2>&1; then
                    warn "Potential filename conflict in $pdf (found ${prefix}_NNNN.${ext}) - proceeding"
                    break
                fi
            done
        else
            prefix="${base}"
            verbose "Using PDF basename as prefix: $prefix"
        fi
    fi
 
    # sanitize prefix (replace spaces with underscore to be safe)
    prefix="${prefix// /_}"
    temp_prefix="${prefix}_temp_$$"  # Use temporary prefix to avoid conflicts
    verbose "Final prefix: $prefix, Temporary prefix: $temp_prefix"

    # --- Extract images ---
    verbose "Starting image extraction using format: $OUTFMT"
    
    if [[ "$OUTFMT" == "tif" ]]; then
        verbose "Running: pdfimages -tiff '$pdf' '${dir}/${temp_prefix}'"
        pdfimages -tiff "$pdf" "${dir}/${temp_prefix}" 2>>"$ERRFILE"
    elif [[ "$OUTFMT" == "jpg" ]]; then
        verbose "Running: pdfimages -j '$pdf' '${dir}/${temp_prefix}'"
        pdfimages -j "$pdf" "${dir}/${temp_prefix}" 2>>"$ERRFILE"
    else
        verbose "Running: pdfimages -all '$pdf' '${dir}/${temp_prefix}'"
        pdfimages -all "$pdf" "${dir}/${temp_prefix}" 2>>"$ERRFILE"
    fi
    local status=$?

    if [[ $status -ne 0 ]]; then
        err "pdfimages failed for $pdf (status $status)"
        find "$dir" -name "${temp_prefix}-*" -type f -delete 2>/dev/null || true
        return 1
    fi

    # List and Count extracted images
    verbose "Counting extracted images..."
    mapfile -t extracted_arr < <(find "$dir" -maxdepth 1 -type f -name "${temp_prefix}-*" -print0 | xargs -0 -r -n1 echo || true)
    imgcount=${#extracted_arr[@]}
    verbose "Extracted $imgcount images"

    if [[ "$imgcount" -eq 0 ]]; then
        err "no images extracted from $pdf"
        return 1
    fi

    # Compare page count and image count and if not cleanup wrong images
    if [[ "$imgcount" -ne "$pages" ]]; then
        # Check if image count is 2x, 3x, 4x pages → likely duplicates
        if (( imgcount == pages*2 || imgcount == pages*3 || imgcount == pages*4 )); then
            warn "Duplicate images detected in $pdf (expected $pages, got $imgcount). Falling back to pdftoppm..."
            verbose "Detected possible duplicate scenario, trying pdftoppm fallback"
            
            # Remove previous extracted images
            find "$dir" -maxdepth 1 -type f -name "${temp_prefix}-*" ! -name "*.pdf" -delete 2>/dev/null || true

            # Extract with pdftoppm
            if [[ "$OUTFMT" == "tif" ]]; then
                verbose "Running: pdftoppm -r 300 -tiff '$pdf' '${dir}/${temp_prefix}'"
                pdftoppm -r 300 -tiff "$pdf" "${dir}/${temp_prefix}" 2>>"$ERRFILE"
            else
                verbose "Running: pdftoppm -r 300 -jpeg '$pdf' '${dir}/${temp_prefix}'"
                pdftoppm -r 300 -jpeg "$pdf" "${dir}/${temp_prefix}" 2>>"$ERRFILE"
            fi

            # Reload extracted files into array
            mapfile -t extracted_arr < <(find "$dir" -maxdepth 1 -type f -name "${temp_prefix}-*" -print0 | xargs -0 -r -n1 echo)
            imgcount=${#extracted_arr[@]}
            verbose "After pdftoppm fallback: $imgcount images"

            # Still mismatch? → fail
            if [[ "$imgcount" -ne "$pages" ]]; then
                err "Fallback with pdftoppm also failed for $pdf (expected $pages, got $imgcount)"
                find "$dir" -maxdepth 1 -type f -name "${temp_prefix}-*" -delete 2>/dev/null || true
                return 1
            fi
        else
            # Normal mismatch, not a duplicate scenario
            find "$dir" -maxdepth 1 -type f -name "${temp_prefix}-*" -delete 2>/dev/null || true
            err "Mismatch in $pdf (expected $pages, got $imgcount)"
            return 1
        fi
    fi
 
    # Rename extracted files with final names (0001, 0002...) and Cleanup on failure
    verbose "Renaming extracted files to final format..."
    local counter=1
    # sort files to ensure order
    IFS=$'\n' sorted=($(printf "%s\n" "${extracted_arr[@]}" | sort))
    unset IFS
    for file in "${sorted[@]}"; do
        ext="${file##*.}"
        newname=$(printf "%s_%04d.%s" "${prefix}" "$counter" "$ext")
        verbose "Renaming: $(basename "$file") -> $(basename "$newname")"
        if ! mv -n -- "$file" "${dir}/${newname}"; then
            err "failed to rename $file to $newname"
            find "$dir" -name "${temp_prefix}-*" -type f -delete 2>/dev/null || true
            find "$dir" -name "${prefix}_*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
            return 1
        fi
        counter=$((counter+1))
    done

    log "SUCCESS: $pdf extracted correctly ($imgcount pages)"
    
    # Move processed PDF, preserving folder structure
    verbose "Moving processed PDF to archive..."
    processed_dir="$WORKDIR/$TMPPDFDIR"
    if [[ -n "$grandparent" && "$grandparent" != "/" && "$grandparent" != "." ]]; then
        processed_dir="$processed_dir/$grandparent/$parent/$curr_dirname"
    else
        processed_dir="$processed_dir/$parent/$curr_dirname"
    fi
    verbose "Target directory: $processed_dir"

    # Create directory structure if needed
    if ! mkdir -p "$processed_dir" 2>>"$ERRFILE"; then
        err "cannot create directory $processed_dir"
        find "$dir" -name "${prefix}_*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
        return 1
    fi
    
    target="$processed_dir/$(basename "$pdf")"
    if [[ -f "$target" ]]; then
        local dupc=1
        while [[ -f "${target%.pdf}_duplicate_${dupc}.pdf" ]]; do ((dupc++)); done
        target="${target%.pdf}_duplicate_${dupc}.pdf"
        warn "Renamed duplicate to $(basename "$target")"
    fi
    
    if mv -n -- "$pdf" "$target"; then
        log "Moved $pdf -> $target"
        verbose "PDF successfully archived"
    else
        err "failed to move $pdf to $target"
        find "$dir" -name "${prefix}_*" -type f ! -name "*.pdf" -delete 2>/dev/null || true
        return 1
    fi

    return 0
}

# --- Main execution starts here ---
parse_arguments "$@"
check_parallel_availability
initialize_script

log "Starting PDF extraction in: $WORKDIR"
log "Output format: $OUTFMT"
if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN MODE: Preview only, no actual processing"
fi
if [[ "$PARALLEL_MODE" == true ]]; then
    log "PARALLEL MODE: Using up to $MAX_JOBS concurrent jobs"
fi
if [[ "$VERBOSE" == true ]]; then
    log "VERBOSE MODE: Detailed output enabled"
fi
log "Log file: $LOGFILE"
log "Error file: $ERRFILE"

if [[ "$PARALLEL_MODE" == true && "$DRY_RUN" == false ]]; then
    log "Running in parallel mode (up to $MAX_JOBS concurrent jobs)"
else
    log "Running in sequential mode (one PDF at a time). It can take a while."
fi

# --- Main processing loop ---
total_pdfs=0
processed_pdfs=0
failed_pdfs=0

verbose "Searching for PDF files..."
mapfile -t -d '' pdf_array < <(
    find "$WORKDIR" -type f -iname '*.pdf' ! -path '*/processed_pdfs/*' -print0
)
total_pdfs=${#pdf_array[@]}

log "Found $total_pdfs PDF files to process"

if [[ "$total_pdfs" -eq 0 ]]; then
    log "No PDF files found in $WORKDIR"
    cleanup_and_exit 0
fi

# Process PDFs based on mode
if [[ "$PARALLEL_MODE" == true && "$DRY_RUN" == false ]]; then
    verbose "Starting parallel processing with $MAX_JOBS jobs"
    # Export functions and variables for parallel
    export -f process_pdf log warn err verbose
    export LOGFILE ERRFILE TMPPDFDIR OUTFMT DRY_RUN VERBOSE WORKDIR
    
    # Use parallel to process PDFs
    printf "%s\n" "${pdf_array[@]}" | parallel -j "$MAX_JOBS" --line-buffer process_pdf
    
    # Count results (this is approximate in parallel mode)
    remaining_pdfs=$(find "$WORKDIR" -type f -iname '*.pdf' ! -path '*/processed_pdfs/*' | wc -l)
    processed_pdfs=$((total_pdfs - remaining_pdfs))
    failed_pdfs=$remaining_pdfs
else
    # Sequential processing (original logic)
    for pdf in "${pdf_array[@]}"; do
        if process_pdf "$pdf"; then
            ((processed_pdfs++)) || true
        else
            ((failed_pdfs++)) || true
        fi
    done
fi

# --- Final summary ---
echo | tee -a "$LOGFILE"
log "=== PROCESSING SUMMARY ==="
log "Total PDFs found: $total_pdfs"
if [[ "$DRY_RUN" == true ]]; then
    log "DRY-RUN completed - no actual processing performed"
else
    log "Successfully processed: $processed_pdfs"
    log "Failed: $failed_pdfs"
fi

# Move final logs to processed_pdfs if possible (skip in dry-run)
if [[ "$DRY_RUN" == false && -d "$WORKDIR/$TMPPDFDIR" ]]; then
    mv -f "$LOGFILE" "$WORKDIR/$TMPPDFDIR/" 2>/dev/null || warn "Failed to move log file to $WORKDIR/$TMPPDFDIR/"
    mv -f "$ERRFILE" "$WORKDIR/$TMPPDFDIR/" 2>/dev/null || warn "Failed to move error file to $WORKDIR/$TMPPDFDIR/"
fi

# Release lock and normal exit
flock -u 200
trap - EXIT
exit 0