#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 -o OLD_MD5 -n NEW_MD5 [options]

Options:
  -o, --old FILE       eski md5 listesi (örnek: old.md5)
  -n, --new FILE       yanlış oluşturulmuş md5 listesi (örnek: new_false.md5)
  -b, --base DIR       base dizin (default: .)
  --verify             her dosyanın gerçek md5'ini hesaplayıp kayıttaki md5 ile doğrula
  --dry-run            hiçbir şey taşınmaz, yapılacak işlemler ekrana yazılır
  --force              hedef dosya varsa üzerine yaz (mv -f)
  -h, --help           bu yardımı göster
EOF
  exit 1
}

# defaults
BASE="."
VERIFY=0
DRY_RUN=0
FORCE=0
OLD=""
NEW=""

# parse args (basic)
ARGS=$(getopt -o o:n:b:h --long old:,new:,base:,verify,dry-run,force,help -n "$0" -- "$@")
if [ $? -ne 0 ]; then usage; fi
eval set -- "$ARGS"
while true; do
  case "$1" in
    -o|--old) OLD="$2"; shift 2;;
    -n|--new) NEW="$2"; shift 2;;
    -b|--base) BASE="$2"; shift 2;;
    --verify) VERIFY=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    --force) FORCE=1; shift;;
    -h|--help) usage; shift;;
    --) shift; break;;
    *) break;;
  esac
done

if [[ -z "$OLD" || -z "$NEW" ]]; then
  echo "Hata: eski ve yeni md5 dosyaları belirtilmelidir."
  usage
fi

if [[ ! -f "$OLD" ]]; then
  echo "Hata: eski md5 dosyası bulunamadı: $OLD" >&2
  exit 2
fi
if [[ ! -f "$NEW" ]]; then
  echo "Hata: yeni md5 dosyası bulunamadı: $NEW" >&2
  exit 2
fi

# helper: parse a line -> prints "md5<TAB>path" or nothing if no md5
parse_line() {
  local line="$1"
  # find first 32-hex md5
  local md5
  md5=$(echo "$line" | grep -Eo '[a-fA-F0-9]{32}' | head -n1 || true)
  if [[ -z "$md5" ]]; then
    return 1
  fi
  # filename is everything after the md5
  local fname
  fname=$(echo "$line" | sed -n "s/.*${md5}[[:space:]]*//p" | sed 's/^[ \t]*//;s/[ \t]*$//')
  # if fname empty, try taking token before or after; but we expect a path after md5
  if [[ -z "$fname" ]]; then
    return 1
  fi
  printf '%s\t%s\n' "$md5" "$fname"
}

declare -A OLD_MAP
declare -A NEW_MAP
declare -A OLD_MULTIPLE

# load old.md5 -> OLD_MAP[md5]=oldpath
while IFS= read -r line || [ -n "$line" ]; do
  out=$(parse_line "$line" || true)
  if [[ -z "$out" ]]; then
    continue
  fi
  md5=${out%%$'\t'*}
  path=${out#*$'\t'}
  if [[ -n "${OLD_MAP[$md5]:-}" ]]; then
    # collision: same md5 maps to multiple old paths
    OLD_MULTIPLE["$md5"]="${OLD_MULTIPLE[$md5]:-}${OLD_MAP[$md5]}||${path}"
    # keep first but note multiples
  else
    OLD_MAP["$md5"]="$path"
  fi
done < "$OLD"

# load new_false.md5 -> NEW_MAP[md5]=newpath
while IFS= read -r line || [ -n "$line" ]; do
  out=$(parse_line "$line" || true)
  if [[ -z "$out" ]]; then
    continue
  fi
  md5=${out%%$'\t'*}
  path=${out#*$'\t'}
  # If duplicates in new list, we keep last but warn later
  if [[ -n "${NEW_MAP[$md5]:-}" ]]; then
    echo "Uyarı: new listesinde aynı md5 birden fazla var: $md5 (öncekini üzerine yazıyorum)" >&2
  fi
  NEW_MAP["$md5"]="$path"
done < "$NEW"

# counters
renamed=0
skipped=0
missing_old=0
missing_file=0
verify_failed=0

logfile="restore_names_by_md5.log"
echo "Restore run at $(date)" > "$logfile"
echo "old_file=$OLD new_file=$NEW base=$BASE verify=$VERIFY dry_run=$DRY_RUN force=$FORCE" >> "$logfile"

# process every md5 in NEW_MAP
for md5 in "${!NEW_MAP[@]}"; do
  newrel="${NEW_MAP[$md5]}"
  oldrel="${OLD_MAP[$md5]:-}"

  if [[ -z "$oldrel" ]]; then
    echo "Atlanıyor: eski listede md5 yok: $md5 <- ${newrel}" | tee -a "$logfile"
    ((missing_old++))
    continue
  fi

  src="$BASE/$newrel"
  dst="$BASE/$oldrel"

  if [[ ! -e "$src" ]]; then
    echo "Dosya bulunamadı: $src (atlandı)" | tee -a "$logfile"
    ((missing_file++))
    continue
  fi

  if [[ "$VERIFY" -eq 1 ]]; then
    # compute md5 of actual file
    actual=$(md5sum "$src" | awk '{print $1}')
    if [[ "$actual" != "$md5" ]]; then
      echo "MD5 uyuşmazlığı: dosya $src, listedeki md5=$md5, gerçek=$actual (atlandı)" | tee -a "$logfile"
      ((verify_failed++))
      continue
    fi
  fi

  dstdir=$(dirname "$dst")
  if [[ -e "$dst" && "$FORCE" -ne 1 ]]; then
    echo "Hedef zaten var ve --force yok: $dst (atlandı)" | tee -a "$logfile"
    ((skipped++))
    continue
  fi

  echo "TAŞIYOR: '$src' -> '$dst'"
  echo "mv: '$src' -> '$dst'" >> "$logfile"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    # just show
    :
  else
    mkdir -p "$dstdir"
    if [[ "$FORCE" -eq 1 ]]; then
      mv -f -- "$src" "$dst"
    else
      mv -- "$src" "$dst"
    fi
  fi

  ((renamed++))
done

# summary
echo "---- Özet ----"
echo "Renamed: $renamed"
echo "Skipped (target existed): $skipped"
echo "Missing in old.md5 (no mapping): $missing_old"
echo "Missing files (source not found): $missing_file"
if [[ "$VERIFY" -eq 1 ]]; then
  echo "Verify failed: $verify_failed"
fi
echo "Ayrıntılar: $logfile"

exit 0