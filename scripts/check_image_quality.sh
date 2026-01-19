#!/usr/bin/env bash
###############################################################################
# Script Name  : check_image_quality.sh
# Purpose      : Identify potentially low-quality archival images (read-only)
# Author       : Mustafa
# Organisation : HladigiTeam
#
# Checks:
#   1. File age >= 15 years
#   2. File size < 5 MB
#   3. Only known image/PDF formats are evaluated
#
# Output:
#   CSV with 5 columns:
#     path | filename | age_check | size_check | reason_summary
#
# Safety:
#   - READ ONLY
#   - No rename, delete, touch, chmod, write
###############################################################################

set -o nounset
set -o pipefail

### CONFIG #############################################################
ROOT_PATH="${1:-}"
OUTPUT="low_quality_candidates.csv"

AGE_YEARS=15
SIZE_LIMIT_MB=5

# accepted file extensions (case-insensitive)
EXT_REGEX='.*\.\(tif\|tiff\|jpg\|jpeg\|pdf\)$'
########################################################################

if [[ -z "$ROOT_PATH" || ! -d "$ROOT_PATH" ]]; then
  echo "Usage: $0 <path>"
  exit 1
fi

# CSV header
echo "path,filename,age_check,size_check,reason" > "$OUTPUT"

CURRENT_EPOCH=$(date +%s)
AGE_LIMIT_SEC=$(( AGE_YEARS * 365 * 24 * 60 * 60 ))
SIZE_LIMIT_BYTES=$(( SIZE_LIMIT_MB * 1024 * 1024 ))

export CURRENT_EPOCH AGE_LIMIT_SEC SIZE_LIMIT_BYTES OUTPUT

find "$ROOT_PATH" -type f \
  -iregex "$EXT_REGEX" \
  -print0 |
while IFS= read -r -d '' file; do

  filename=$(basename "$file")
  filepath=$(dirname "$file")

  ### AGE CHECK ########################################################
  mtime=$(stat -c %Y "$file")
  age_diff=$(( CURRENT_EPOCH - mtime ))

  if (( age_diff >= AGE_LIMIT_SEC )); then
    age_check="AGE_15Y+"
  else
    age_check="OK"
  fi

  ### SIZE CHECK #######################################################
  size=$(stat -c %s "$file")

  if (( size < SIZE_LIMIT_BYTES )); then
    size_check="SIZE_LT_5MB"
  else
    size_check="OK"
  fi

  ### DECISION #########################################################
  if [[ "$age_check" != "OK" || "$size_check" != "OK" ]]; then
    reason=$(printf "%s;%s" "$age_check" "$size_check")
    echo "\"$filepath\",\"$filename\",\"$age_check\",\"$size_check\",\"$reason\"" \
      >> "$OUTPUT"
  fi

done

echo "Scan completed."
echo "Result file: $OUTPUT"
