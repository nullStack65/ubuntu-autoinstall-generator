#!/usr/bin/env bash
set -euo pipefail

# === CONFIG & DEFAULTS ===
WORKDIR="./iso_work"
ISO=""
DEST=""
VALIDATE_ONLY=false
HTTP_SERVER="${HTTP_SERVER:-127.0.0.1}"
HTTP_PORT="${HTTP_PORT:-8000}"

# Kernel parameters to enable autoinstall + fetch user-data from Packer HTTP server.
# The trailing slash is required so cloud-init will look for:
#   http://${HTTP_SERVER}:${HTTP_PORT}/user-data
#   http://${HTTP_SERVER}:${HTTP_PORT}/meta-data
BOOT_PARAMS="autoinstall ds=nocloud-net;s=http://${HTTP_SERVER}:${HTTP_PORT}/"

# === LOGGING & ERRORS ===
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
    -h|--help)       usage             ;;
    *.iso)           ISO="$1";          shift   ;;
    *)               echo "Unknown arg: $1"; usage ;;
  esac
done

  [[ -f "$ISO" ]] || error "ISO file not found: $ISO"

  if [[ -z "$DEST" ]]; then
    BASENAME=$(basename "$ISO" .iso)
    DEST="${BASENAME}-autoinstall.iso"
  fi

  # Recompute BOOT_PARAMS in case HTTP_SERVER/PORT changed
  BOOT_PARAMS="autoinstall ds=nocloud-net;s=http://${HTTP_SERVER}:${HTTP_PORT}/"
}

# === ISO INSPECTION ===
extract_version() {
  mkdir -p "$WORKDIR"
  xorriso -osirrox on -indev "$ISO" \
    -extract /.disk/info "$WORKDIR/info.txt" \
    || return
  VERSION=$(grep -Eo '[0-9]+\.[0-9]+' "$WORKDIR/info.txt" | head -n1 || echo "Unknown")
  log "Detected Ubuntu version: $VERSION"
}

detect_structure() {
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

# === PATCHING FUNCTION ===
# Uses xorriso -map to override the in-ISO boot config without full re-extract
# === PATCHING FUNCTION ===
patch_kernel_params() {
  local path_in_iso cfg_local tmp_iso

  case "$FORMAT" in
    "Live Server"|"GRUB EFI")
      path_in_iso="/boot/grub/grub.cfg"
      ;;
    "Legacy Boot")
      path_in_iso="/isolinux/txt.cfg"
      ;;
    *)
      error "Unsupported ISO format for patching: $FORMAT"
      ;;
  esac

  # Extract just the boot config so we only rewrite one file
  cfg_local="$WORKDIR/boot.cfg"
  xorriso -osirrox on -indev "$DEST" \
    -extract "$path_in_iso" "$cfg_local"

  # Use sed to find the "linux" line and replace the "---" with the autoinstall parameters + "---"
  # This ensures the parameters are in the correct position for the Ubuntu installer.
  sed -i "s|^\( *linux .*\)---$|\1 ${BOOT_PARAMS}---|" "$cfg_local"

  # Remap the single patched file back into the ISO
  tmp_iso="${DEST%.iso}-tmp.iso"
  xorriso -indev "$DEST" \
          -outdev "$tmp_iso" \
          -map "$cfg_local" "$path_in_iso"

  mv "$tmp_iso" "$DEST"
  log "Patched kernel params in $path_in_iso"
}


# === ISO REBUILD ===
build_output() {
  if [[ -f "$DEST" ]]; then
    log "Found existing $DEST — skipping full extract/repack"
  else
    log "Copying base ISO → $DEST"
    cp "$ISO" "$DEST"
  fi

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