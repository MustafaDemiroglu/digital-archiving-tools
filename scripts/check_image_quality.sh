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
#   Stage 1 (fast):
#     - File age >= 15 years
#     - File size < 5 MB
#
#   Stage 2 (ImageMagick):
#     - DPI < 300 (if available)
#     - Resolution < 800x600
#     - Pixel count < 2 MP
#
# Output:
#     CSV with quality indicators
#
# Safety:
#   - READ ONLY
#   - No rename, delete, touch, chmod, write
###############################################################################

set -o nounset
set -o pipefail

# CONFIG 
ROOT_PATH="${1:-}"
OUTPUT="low_quality_candidates.csv"

AGE_YEARS=15
SIZE_LIMIT_MB=5
MIN_DPI=300
MIN_WIDTH=800
MIN_HEIGHT=600
MIN_PIXELS=2000000

# accepted file extensions (case-insensitive)
EXT_REGEX='.*\.\(tif\|tiff\|jpg\|jpeg\)$'

if [[ -z "$ROOT_PATH" || ! -d "$ROOT_PATH" ]]; then
  echo "Usage: $0 <path>"
  exit 1
fi

# CSV header
echo "Pfad,Dateiname,Altersprüfung,Größenprüfung,DPI,Auflösung,Pixelzahl,Hinweis" > "$OUTPUT"

CURRENT_EPOCH=$(date +%s)
AGE_LIMIT_SEC=$(( AGE_YEARS * 365 * 24 * 60 * 60 ))
SIZE_LIMIT_BYTES=$(( SIZE_LIMIT_MB * 1024 * 1024 ))

find "$ROOT_PATH" -type f \
  -iregex "$EXT_REGEX" \
  -print0 |
while IFS= read -r -d '' file; do

  filename=$(basename "$file")
  filepath=$(dirname "$file")

  # AGE CHECK
  mtime=$(stat -c %Y "$file")
  age_diff=$(( CURRENT_EPOCH - mtime ))

  if (( age_diff >= AGE_LIMIT_SEC )); then
    # age_check="AGE_15Y+"
    age_check="Aelter als 15 Jahre"
  else
    age_check="OK"
  fi

  # SIZE CHECK
  size=$(stat -c %s "$file")

  if (( size < SIZE_LIMIT_BYTES )); then
    # size_check="SIZE_LT_5MB"
    size_check="Kleiner als 5 MB"
  else
    size_check="OK"
  fi

  # Stage 1 Filter
  if [[ "$age_check" == "OK" && "$size_check" == "OK" ]]; then
    continue
  fi
  
  # IMAGEMAGICK ANALYSIS
  dpi_check="OK"
  resolution_check="OK"
  pixel_check="OK"

  width=""
  height=""
  dpi=""
  dpi_numeric=""
  
	if identify_output=$(identify -ping -format "%w;%h;%x" "$file" 2>/dev/null); then

        IFS=';' read -r width height dpi <<< "$identify_output"

        # DPI CHECK
        if [[ $dpi =~ ^([0-9]+(\.[0-9]+)?) ]]; then
			dpi_numeric="${BASH_REMATCH[1]}"
		fi

        if [[ -n "$dpi_numeric" ]]; then
            dpi_int=${dpi_numeric%.*}

            if (( dpi_int < MIN_DPI )); then
                dpi_check="<300 DPI"
            fi
        else
            dpi_check="Keine DPI-Info"
        fi

        # RESOLUTION CHECK
        if (( width < MIN_WIDTH || height < MIN_HEIGHT )); then
            resolution_check="<800x600"
        fi

        # PIXEL CHECK
        pixels=$(( width * height ))
        if (( pixels < MIN_PIXELS )); then
            pixel_check="<2 MP"
        fi
    else
        dpi_check="Analysefehler"
        resolution_check="Analysefehler"
        pixel_check="Analysefehler"
    fi
	
	# FINAL DECISION
	quality_problem=false
	reason=""

	if [[ "$dpi_check" == "<300 DPI" ]]; then
		quality_problem=true
		reason="${reason:+$reason + }Niedrige DPI"
	fi

	if [[ "$resolution_check" == "<800x600" ]]; then
		quality_problem=true
		reason="${reason:+$reason + }Niedrige Auflösung"
	fi

	if [[ "$pixel_check" == "<2 MP" ]]; then
		quality_problem=true
		reason="${reason:+$reason + }Wenig Pixel"
	fi
	
	if [[ "$dpi_check" == "Analysefehler" ]]; then
		quality_problem=true
		reason="${reason:+$reason + }Analysefehler"
	fi

	if [[ "$quality_problem" == true ]]; then
		echo "\"$filepath\",\"$filename\",\"$age_check\",\"$size_check\",\"$dpi_check\",\"$resolution_check\",\"$pixel_check\",\"$reason\"" \
			>> "$OUTPUT"
	fi
done

echo "Scan completed."
echo "Result file: $OUTPUT"