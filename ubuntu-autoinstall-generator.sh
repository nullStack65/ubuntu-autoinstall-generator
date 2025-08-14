#!/usr/bin/env bash
set -euo pipefail

WORKDIR="./iso_work"
ISO=""
DEST=""
VALIDATE_ONLY=false
HTTP_SERVER="${HTTP_SERVER:-127.0.0.1}"
HTTP_PORT="${HTTP_PORT:-8000}"
BOOT_PARAMS="autoinstall ds=nocloud-net;s=http://${HTTP_SERVER}:${HTTP_PORT}/"

log()   { echo "[$(date +'%H:%M:%S')] 🔹 $1"; }
error() { echo "[$(date +'%H:%M:%S')] ❌ $1" >&2; exit 1; }

usage() {
  echo "Usage: $0 --source <ubuntu-*.iso> [--destination <out.iso>] [--http-server host] [--http-port port] [--validate-only]"
  exit 1
}

check_dependencies() {
  for cmd in xorriso grep awk sed; do
    command -v "$cmd" >/dev/null || error "Missing dependency: $cmd"
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source)        ISO="$2";          shift 2 ;;
      --destination)   DEST="$2";         shift 2 ;;
      --validate-only) VALIDATE_ONLY=true; shift ;;
      --http-server)   HTTP_SERVER="$2";  shift 2 ;;
      --http-port)     HTTP_PORT="$2";    shift 2 ;;
      -h|--help)       usage ;;
      *.iso)           ISO="$1";          shift ;;
      *)               echo "Unknown arg: $1"; usage ;;
    esac
  done

  [[ -f "$ISO" ]] || error "ISO file not found: $ISO"

  if [[ -z "${DEST:-}" ]]; then
    BASENAME=$(basename "$ISO" .iso)
    DEST="${BASENAME}-autoinstall.iso"
  fi

  BOOT_PARAMS="autoinstall ds=nocloud-net;s=http://${HTTP_SERVER}:${HTTP_PORT}/"
}

extract_version() {
  mkdir -p "$WORKDIR"
  if xorriso -osirrox on -indev "$ISO" -extract /.disk/info "$WORKDIR/info.txt" >/dev/null 2>&1; then
    VERSION=$(grep -Eo '[0-9]+\.[0-9]+' "$WORKDIR/info.txt" | head -n1 || true)
    VERSION="${VERSION:-Unknown}"
  else
    VERSION="Unknown"
  fi
  log "Detected Ubuntu version: $VERSION"
}

detect_structure() {
  mkdir -p "$WORKDIR"
  xorriso -indev "$ISO" -find / -type f > "$WORKDIR/files.txt"
  if grep -q "casper/vmlinuz" "$WORKDIR/files.txt"; then
    FORMAT="Live Server"
  elif grep -q "boot/grub" "$WORKDIR/files.txt"; then
    FORMAT="GRUB EFI"
  elif grep -q "isolinux/txt.cfg" "$WORKDIR/files.txt"; then
    FORMAT="Legacy Boot"
  else
    FORMAT="Unknown"
  fi
  log "Detected ISO format: $FORMAT"
}

validate_iso() {
  extract_version
  detect_structure
  [[ "$VALIDATE_ONLY" != true ]] || { log "Validation complete ✅"; exit 0; }
}

copy_base_iso() {
  log "Copying base ISO → $DEST"
  cp -f "$ISO" "$DEST"
}

collect_candidate_cfgs() {
  awk '
    /\/(boot\/grub|grub)\// && /\.cfg$/ {print}
    /\/isolinux\/txt\.cfg$/             {print}
    /\/syslinux\/.*\.cfg$/              {print}
  ' "$WORKDIR/files.txt" | sort -u > "$WORKDIR/candidates.txt"

  # Add common fallbacks explicitly (in case Rock Ridge listings are odd)
  {
    echo "/boot/grub/grub.cfg"
    echo "/boot/grub/loopback.cfg"
    echo "/grub/grub.cfg"
    echo "/isolinux/txt.cfg"
    echo "/boot/grub/x86_64-efi/grub.cfg"
    echo "/EFI/BOOT/grub.cfg"
  } >> "$WORKDIR/candidates.txt"

  sort -u "$WORKDIR/candidates.txt" -o "$WORKDIR/candidates.txt"
}

extract_if_exists() {
  local iso_path="$1" out_local="$2"
  mkdir -p "$(dirname "$out_local")"
  if xorriso -osirrox on -indev "$ISO" -extract "$iso_path" "$out_local" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

patch_grub_file() {
  local file="$1"
  local tmp="$file.tmp"
  cp -f "$file" "$tmp"

  sed -E -i '
    /^\s*linux(efi)?\s/ {
      /ds=nocloud/ b
      s/^( *linux(efi)?[[:space:]]+[^#\r\n]*?)\s*---(.*)$/\1 '"$BOOT_PARAMS"'---\3/
      t
      s/$/ '" $BOOT_PARAMS "'---/
    }
  ' "$tmp"

  if ! grep -q "ds=nocloud-net" "$tmp"; then
    return 1
  fi

  mv -f "$tmp" "$file"
  return 0
}

patch_syslinux_file() {
  local file="$1"
  local tmp="$file.tmp"
  cp -f "$file" "$tmp"

  sed -E -i '
    /^\s*append[[:space:]]/ {
      /ds=nocloud/ b
      s/^( *append[[:space:]]+[^#\r\n]*?)\s*---(.*)$/\1 '"$BOOT_PARAMS"'---\2/
      t
      s/$/ '" $BOOT_PARAMS "'---/
    }
  ' "$tmp"

  if ! grep -q "ds=nocloud-net" "$tmp"; then
    return 1
  fi

  mv -f "$tmp" "$file"
  return 0
}

patch_kernel_params() {
  local patched_any=false
  local cfg_local iso_path kind

  while IFS= read -r iso_path; do
    [[ -n "$iso_path" ]] || continue
    cfg_local="$WORKDIR/extract${iso_path}"
    if extract_if_exists "$iso_path" "$cfg_local"; then
      if grep -Eq '^\s*(linux(efi)?|append)\s' "$cfg_local"; then
        if grep -Eq '^\s*append\s' "$cfg_local"; then
          kind="syslinux"
          if patch_syslinux_file "$cfg_local"; then
            patched_any=true
            log "Patched syslinux: $iso_path"
          fi
        else
          kind="grub"
          if patch_grub_file "$cfg_local"; then
            patched_any=true
            log "Patched grub: $iso_path"
          fi
        fi
      fi
    fi
  done < "$WORKDIR/candidates.txt"

  [[ "$patched_any" == true ]] || error "No editable kernel lines found to patch."

  local tmp_iso
  tmp_iso="${DEST%.iso}-tmp.iso"
  cp -f "$DEST" "$tmp_iso"

  while IFS= read -r iso_path; do
    [[ -n "$iso_path" ]] || continue
    cfg_local="$WORKDIR/extract${iso_path}"
    if [[ -f "$cfg_local" ]] && grep -q "ds=nocloud-net" "$cfg_local"; then
      xorriso -indev "$tmp_iso" -outdev "$tmp_iso.new" -map "$cfg_local" "$iso_path" >/dev/null 2>&1 \
        && mv -f "$tmp_iso.new" "$tmp_iso" \
        || error "Failed to map back: $iso_path"
    fi
  done < "$WORKDIR/candidates.txt"

  mv -f "$tmp_iso" "$DEST"
  log "✅ Kernel params patched in all matching boot configs"

  local verify_ok=false
  while IFS= read -r iso_path; do
    [[ -n "$iso_path" ]] || continue
    if xorriso -osirrox on -indev "$DEST" -extract "$iso_path" "$WORKDIR/verify.cfg" >/dev/null 2>&1; then
      if grep -q "ds=nocloud-net" "$WORKDIR/verify.cfg"; then
        verify_ok=true
        break
      fi
    fi
  done < "$WORKDIR/candidates.txt"

  [[ "$verify_ok" == true ]] || error "Autoinstall params missing after patch."
  log "✅ Verified autoinstall params present"
}

build_output() {
  copy_base_iso
  collect_candidate_cfgs
  patch_kernel_params
  log "✅ Output ISO ready: $DEST"
}

cleanup() {
  rm -rf "$WORKDIR"
}

check_dependencies
parse_args "$@"
validate_iso
build_output
cleanup
exit 0
