#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="${1:-}"

if [[ -z "$ROOT_DIR" ]]; then
    echo "Usage: $0 <root_directory>"
    exit 1
fi

if [[ ! -d "$ROOT_DIR" ]]; then
    echo "Directory not found: $ROOT_DIR"
    exit 1
fi

echo "Starting rename process in: $ROOT_DIR"
echo

find "$ROOT_DIR" -type f -name "*.jpg" | while read -r file; do

    sig_dir=$(dirname "$file")
    bestand_dir=$(dirname "$sig_dir")
    haus_dir=$(dirname "$bestand_dir")

    sig=$(basename "$sig_dir")
    bestand=$(basename "$bestand_dir")
    haus=$(basename "$haus_dir")

    filename=$(basename "$file")

    newname="${haus}_${bestand}_nr_${sig}_${filename}"
    newpath="${sig_dir}/${newname}"

    # skip if already renamed
    if [[ "$filename" == "$newname" ]]; then
        continue
    fi

    if [[ -e "$newpath" ]]; then
        echo "WARNING: target exists, skipping $file"
        continue
    fi

    echo "Renaming:"
    echo "  $file"
    echo "  -> $newpath"

    mv "$file" "$newpath"

done

echo
echo "Rename finished."