#!/bin/bash
# ubuntu-autoinstall-generator.sh
# Generates a fully-automated Ubuntu 22.04+ ISO that boots and fetches autoinstall config from a HTTP server.

set -euo pipefail

# ----------------------------
# Arguments
# ----------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source) SOURCE_ISO="$2"; shift 2 ;;
        --destination) DEST_ISO="$2"; shift 2 ;;
        --http-server) HTTP_IP="$2"; shift 2 ;;
        --http-port) HTTP_PORT="$2"; shift 2 ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "${SOURCE_ISO:-}" || -z "${DEST_ISO:-}" || -z "${HTTP_IP:-}" || -z "${HTTP_PORT:-}" ]]; then
    echo "Usage: $0 --source <source_iso> --destination <dest_iso> --http-server <ip> --http-port <port>"
    exit 1
fi

echo "[GENERATOR] Using base ISO: $SOURCE_ISO"
echo "[GENERATOR] Output ISO: $DEST_ISO"
AUTOINSTALL_ARGS="autoinstall ds=nocloud-net;s=http://$HTTP_IP:$HTTP_PORT/"

WORK_DIR=$(mktemp -d)
trap "rm -rf $WORK_DIR" EXIT

# ----------------------------
# Mount ISO
# ----------------------------
mkdir -p "$WORK_DIR/iso"
mount -o loop,ro "$SOURCE_ISO" "$WORK_DIR/iso"

# ----------------------------
# Copy ISO contents
# ----------------------------
mkdir -p "$WORK_DIR/edit"
rsync -a --exclude=/casper/filesystem.squashfs "$WORK_DIR/iso/" "$WORK_DIR/edit/"

# ----------------------------
# Patch BIOS grub.cfg
# ----------------------------
GRUB_CFG="$WORK_DIR/edit/boot/grub/grub.cfg"
if [[ -f "$GRUB_CFG" ]]; then
    echo "[GENERATOR] Patching BIOS grub.cfg..."
    sed -i -r "s|^(        linux\s+/casper/.*vmlinuz\s+)(---)?|\1$AUTOINSTALL_ARGS |" "$GRUB_CFG"
fi

# ----------------------------
# Patch EFI loopback.cfg if it exists
# ----------------------------
EFI_CFG="$WORK_DIR/edit/boot/grub/loopback.cfg"
if [[ -f "$EFI_CFG" ]]; then
    echo "[GENERATOR] Patching EFI loopback.cfg..."
    sed -i -r "s|^(        linux\s+/casper/.*vmlinuz\s+)(---)?|\1$AUTOINSTALL_ARGS |" "$EFI_CFG"
fi

# ----------------------------
# Rebuild ISO
# ----------------------------
echo "[GENERATOR] Rebuilding ISO..."
xorriso -as mkisofs \
  -r -V "Ubuntu-Server 22.04-autoinstall" \
  -o "$DEST_ISO" \
  -J -joliet-long -cache-inodes \
  -isohybrid-mbr "$WORK_DIR/edit/boot/grub/i386-pc/eltorito.img" \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img -no-emul-boot \
  -isohybrid-gpt-basdat \
  "$WORK_DIR/edit"

echo "[GENERATOR] Done! ISO saved as $DEST_ISO"
