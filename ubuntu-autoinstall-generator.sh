#!/usr/bin/env bash
set -euo pipefail

# === CONFIG & DEFAULTS ===
WORKDIR="./iso_work"
ISO=""
DEST=""
VALIDATE_ONLY=false
HTTP_SERVER="${HTTP_SERVER:-127.0.0.1}"
HTTP_PORT="${HTTP_PORT:-8000}"
BOOT_PARAMS="autoinstall ds=nocloud-net;s=http://${HTTP_SERVER}:${HTTP_PORT}/"

# === LOGGING ===
log()   { echo "[$(date +'%H:%M:%S')] 🔹 $1"; }
error() { echo "[$(date +'%H:%M:%S')] ❌ $1" >&2; exit 1; }

# === DEPENDENCY CHECK ===
check_dependencies() {
  for cmd in xorriso grep awk sed; do
    command -v "$cmd" >/dev/null || error "Missing dependency: $cmd"
  done
}

# === ARG PARSING ===
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source)        ISO="$2";          shift 2 ;;
      --destination)   DEST="$2";         shift 2 ;;
      --validate-only) VALIDATE_ONLY=true; shift   ;;
      --http-server)   HTTP_SERVER="$2";  shift 2 ;;
      --http-port)     HTTP_PORT="$2";    shift 2 ;;
      -h|--help)       usage ;;
      *.iso)           ISO="$1";          shift   ;;
      *)               echo "Unknown arg: $1"; usage ;;
    esac
  done

  [[ -f "$ISO" ]] || error "ISO file not found: $ISO"

  if [[ -z "$DEST" ]]; then
    BASENAME=$(basename "$ISO" .iso)
    DEST="${BASENAME}-autoinstall.iso"
  fi

  BOOT_PARAMS="autoinstall ds=nocloud-net;s=http://${HTTP_SERVER}:${HTTP_PORT}/"
}

# === ISO INSPECTION ===
extract_version() {
  mkdir -p "$WORKDIR"
  xorriso -osirrox on -indev "$ISO" \
    -extract /.disk/info "$WORKDIR/info.txt" || return
  VERSION=$(grep -Eo '[0-9]+\.[0-9]+' "$WORKDIR/info.txt" | head -n1 || echo "Unknown")
  log "Detected Ubuntu version: $VERSION"
}

detect_structure() {
  log "Scanning ISO file list..."
  mkdir -p "$WORKDIR"
  xorriso -indev "$ISO" -find / -type f > "$WORKDIR/files.txt"

  # Detect format
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

  # Try to locate grub.cfg directly in ISO tree
  GRUB_PATH=$(grep -E '/grub\.cfg$' "$WORKDIR/files.txt" | head -n1 || true)

  if [[ -n "$GRUB_PATH" ]]; then
    log "Found grub.cfg in main ISO at: $GRUB_PATH"
    return
  fi

  log "No grub.cfg found in main ISO — checking EFI boot image..."

  # Extract EFI boot image
  mkdir -p "$WORKDIR/efi"
  # This path can vary, but most Ubuntu ISOs have [BOOT]/1 or /boot/grub/efi.img
  EFI_IMAGE=$(
    grep -E '/boot/grub/efi\.img$|^\[BOOT\]/1$' "$WORKDIR/files.txt" | head -n1 || true
  )

  if [[ -z "$EFI_IMAGE" ]]; then
    error "Could not locate EFI image in ISO to search for grub.cfg"
  fi

  log "Extracting EFI image: $EFI_IMAGE"
  xorriso -osirrox on -indev "$ISO" -extract "$EFI_IMAGE" "$WORKDIR/boot.img"

  # Mount EFI image and search inside
  mkdir -p "$WORKDIR/efimnt"
  sudo mount -o loop "$WORKDIR/boot.img" "$WORKDIR/efimnt" || error "Failed to mount EFI image"
  GRUB_PATH=$(find "$WORKDIR/efimnt" -name grub.cfg | head -n1 || true)

  sudo umount "$WORKDIR/efimnt"

  if [[ -z "$GRUB_PATH" ]]; then
    error "Could not locate grub.cfg in EFI image."
  fi

  log "Found grub.cfg inside EFI image at: $GRUB_PATH"
}

validate_iso() {
  extract_version
  detect_structure
  [[ "$VALIDATE_ONLY" != true ]] || { log "Validation complete ✅"; exit 0; }
}

# === PATCHING FUNCTION ===
patch_kernel_params() {
  local cfg_local tmp_iso

  cfg_local="$WORKDIR/boot.cfg"
  xorriso -osirrox on -indev "$DEST" -extract "$GRUB_PATH" "$cfg_local"

  log "Original linux lines in grub.cfg:"
  grep -E '^\s*linux ' "$cfg_local"

  # Replace "---" or "--" with autoinstall params
  sed -i -E "s|^( *linux .*)(--+.*)?$|\1 ${BOOT_PARAMS}---|" "$cfg_local"

  log "Patched linux lines:"
  grep -E '^\s*linux ' "$cfg_local"

  tmp_iso="${DEST%.iso}-tmp.iso"
  xorriso -indev "$DEST" \
          -outdev "$tmp_iso" \
          -map "$cfg_local" "$GRUB_PATH"

  mv "$tmp_iso" "$DEST"
  log "✅ Kernel params patched in $GRUB_PATH"

  # Verification step
  xorriso -osirrox on -indev "$DEST" -extract "$GRUB_PATH" "$WORKDIR/verify.cfg"
  if grep -q "ds=nocloud-net" "$WORKDIR/verify.cfg"; then
    log "✅ Verified autoinstall params present in grub.cfg"
  else
    error "❌ Autoinstall params missing after patch"
  fi
}

# === ISO REBUILD ===
build_output() {
  log "Copying base ISO → $DEST"
  cp "$ISO" "$DEST"

  log "Injecting autoinstall + Packer HTTP params..."
  patch_kernel_params

  log "✅ Output ISO ready: $DEST"
}

cleanup() {
  rm -rf "$WORKDIR"
}

# === MAIN ===
check_dependencies
parse_args "$@"
validate_iso
build_output
cleanup
exit 0
