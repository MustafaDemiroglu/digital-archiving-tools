#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Kullanım:
  $0 -o OLD_MD5 -d DIR [options]

Örnek:
  $0 -o old.md5 -d hstam/4_b/581 --dry-run
  $0 -o old.md5 -d hstam/4_b/581 --recursive

Seçenekler:
  -o, --old FILE        eski md5 listesi (örnek: old.md5)
  -d, --dir DIR         yanlış isimli dosyaların bulunduğu dizin
  -r, --recursive       alt dizinlerde de ara (default: sadece verilen dizin)
      --dry-run         gerçek taşıma/yenidenadlandırma yapma, sadece göster
      --overwrite       hedef dosya varsa üzerine yaz
  -h, --help            bu yardımı göster
EOF
  exit 1
}

OLD=""
DIR=""
RECURSIVE=0
DRY_RUN=0
OVERWRITE=0

ARGS=$(getopt -o o:d:rh --long old:,dir:,recursive,dry-run,overwrite,help -n "$0" -- "$@") || usage
eval set -- "$ARGS"
while true; do
  case "$1" in
    -o|--old) OLD="$2"; shift 2;;
    -d|--dir) DIR="$2"; shift 2;;
    -r|--recursive) RECURSIVE=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --overwrite) OVERWRITE=1; shift;;
    -h|--help) usage; shift;;
    --) shift; break;;
    *) break;;
  esac
done

if [[ -z "$OLD" || -z "$DIR" ]]; then
  echo "Hata: -o (old.md5) ve -d (directory) gereklidir." >&2
  usage
fi

if [[ ! -f "$OLD" ]]; then
  echo "Hata: old.md5 bulunamadı: $OLD" >&2
  exit 2
fi

if [[ ! -d "$DIR" ]]; then
  echo "Hata: belirtilen dizin bulunamadı: $DIR" >&2
  exit 2
fi

# read old.md5 -> map md5 -> target basename
declare -A TARGET_BY_MD5
declare -A DUPLICATE_MD5

while IFS= read -r line || [ -n "$line" ]; do
  # md5 anywhere in line (handles lines with leading numbers)
  md5=$(echo "$line" | grep -Eo '[a-fA-F0-9]{32}' | head -n1 || true)
  if [[ -z "$md5" ]]; then
    continue
  fi
  # extract path after md5 (or any token after); fall back to last token
  rest=$(echo "$line" | sed -n "s/.*${md5}[[:space:]]*//p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [[ -z "$rest" ]]; then
    # fallback: take last whitespace-separated token
    rest=$(echo "$line" | awk '{print $NF}')
  fi
  tgt_basename=$(basename "$rest")
  if [[ -z "${TARGET_BY_MD5[$md5]:-}" ]]; then
    TARGET_BY_MD5[$md5]="$tgt_basename"
  else
    # duplicate md5 -> multiple targets
    DUPLICATE_MD5[$md5]="${DUPLICATE_MD5[$md5]:-}${TARGET_BY_MD5[$md5]}|${tgt_basename}"
    # keep first mapping
  fi
done < "$OLD"

if [[ ${#TARGET_BY_MD5[@]} -eq 0 ]]; then
  echo "Uyarı: old.md5 dosyasından hiç md5 okunamadı." >&2
  exit 3
fi

# find files to check
if [[ "$RECURSIVE" -eq 1 ]]; then
  mapfile -d '' files < <(find "$DIR" -type f -print0)
else
  mapfile -d '' files < <(find "$DIR" -maxdepth 1 -type f -print0)
fi

if [[ ${#files[@]} -eq 0 ]]; then
  echo "Dizinde hiçbir dosya bulunamadı: $DIR" >&2
  exit 4
fi

renamed=0
skipped=0
no_match=0
conflicts=0

echo "Toplam dosya: ${#files[@]}"
echo "Toplam eski-md5 kayıt: ${#TARGET_BY_MD5[@]}"
echo

for file in "${files[@]}"; do
  # file may include trailing NUL, remove it
  f="${file%$'\0'}"
  # compute md5
  if ! md5=$(md5sum "$f" 2>/dev/null | awk '{print $1}'); then
    echo "md5 hesaplanamadı: $f (atlandı)"
    ((skipped++))
    continue
  fi

  tgt_basename="${TARGET_BY_MD5[$md5]:-}"
  if [[ -z "$tgt_basename" ]]; then
    echo "Eşleşme yok (md5 bulunamadı): $f -> md5=$md5"
    ((no_match++))
    continue
  fi

  cur_basename=$(basename "$f")
  if [[ "$cur_basename" == "$tgt_basename" ]]; then
    echo "Zaten doğru isimde: $cur_basename"
    continue
  fi

  dst_dir=$(dirname "$f")
  dst="$dst_dir/$tgt_basename"

  if [[ -e "$dst" && "$OVERWRITE" -ne 1 ]]; then
    echo "Hedef zaten var ve --overwrite yok: '$dst' (atlandı)  (kaynak: $f)"
    ((conflicts++))
    continue
  fi

  echo "RENAMING: '$f' -> '$dst'"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    mv -f -- "$f" "$dst"
  fi
  ((renamed++))
done

echo
echo "Özet:"
echo "Renamed: $renamed"
echo "No md5 match: $no_match"
echo "Skipped (md5 fail/etc): $skipped"
echo "Conflicts (target exists): $conflicts"
if [[ ${#DUPLICATE_MD5[@]} -gt 0 ]]; then
  echo
  echo "Uyarı: old.md5 içinde aynı md5 için birden fazla hedef ismi var (ilkini kullandım):"
  for k in "${!DUPLICATE_MD5[@]}"; do
    echo "$k -> ${DUPLICATE_MD5[$k]}"
  done
fi

exit 0