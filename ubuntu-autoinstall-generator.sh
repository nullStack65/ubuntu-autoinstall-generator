#!/usr/bin/env bash
set -euo pipefail

# --- Arguments ---
SOURCE=""
DESTINATION=""
HTTP_SERVER=""
HTTP_PORT=""

usage() {
    echo "Usage: $0 --source <source_iso> --destination <dest_iso> --http-server <ip> --http-port <port>"
    exit 1
}

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)
            SOURCE="$2"
            shift 2
            ;;
        --destination)
            DESTINATION="$2"
            shift 2
            ;;
        --http-server)
            HTTP_SERVER="$2"
            shift 2
            ;;
        --http-port)
            HTTP_PORT="$2"
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

if [[ -z "$SOURCE" || -z "$DESTINATION" || -z "$HTTP_SERVER" || -z "$HTTP_PORT" ]]; then
    usage
fi

AUTOINSTALL_ARGS="autoinstall ds=nocloud-net\\;s=http://${HTTP_SERVER}:${HTTP_PORT}/"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "[GENERATOR] Using base ISO: $SOURCE"
echo "[GENERATOR] Output ISO: $DESTINATION"
echo "[GENERATOR] Autoinstall args: $AUTOINSTALL_ARGS"

# 1. Mount ISO and copy contents
mkdir -p "$WORK_DIR/iso"
mount -o loop "$SOURCE" "$WORK_DIR/iso"
rsync -a "$WORK_DIR/iso/" "$WORK_DIR/edit/"
umount "$WORK_DIR/iso"

# 2. Patch BIOS grub.cfg (default menu entry only)
if [ -f "$WORK_DIR/edit/boot/grub/grub.cfg" ]; then
    echo "[GENERATOR] Patching BIOS grub.cfg..."
    awk -v args="$AUTOINSTALL_ARGS" '
        BEGIN { in_entry=0; patched=0 }
        /^menuentry / {
            if (!patched) { in_entry=1 }
        }
        in_entry && /^\s+linux\s/ {
            sub(/---$/, args " ---")
            in_entry=0
            patched=1
        }
        { print }
    ' "$WORK_DIR/edit/boot/grub/grub.cfg" > "$WORK_DIR/edit/boot/grub/grub.cfg.tmp"
    mv "$WORK_DIR/edit/boot/grub/grub.cfg.tmp" "$WORK_DIR/edit/boot/grub/grub.cfg"
fi

# 3. Patch UEFI loopback.cfg (default menu entry only)
EFI_IMG="$WORK_DIR/edit/boot/grub/efi.img"
if [ -f "$EFI_IMG" ]; then
    echo "[GENERATOR] Patching UEFI loopback.cfg..."
    mkdir -p "$WORK_DIR/efi_mount"
    mount -o loop "$EFI_IMG" "$WORK_DIR/efi_mount"

    if [ -f "$WORK_DIR/efi_mount/boot/grub/loopback.cfg" ]; then
        awk -v args="$AUTOINSTALL_ARGS" '
            BEGIN { in_entry=0; patched=0 }
            /^menuentry / {
                if (!patched) { in_entry=1 }
            }
            in_entry && /^\s+linux\s/ {
                sub(/---$/, args " ---")
                in_entry=0
                patched=1
            }
            { print }
        ' "$WORK_DIR/efi_mount/boot/grub/loopback.cfg" > "$WORK_DIR/efi_mount/boot/grub/loopback.cfg.tmp"
        mv "$WORK_DIR/efi_mount/boot/grub/loopback.cfg.tmp" "$WORK_DIR/efi_mount/boot/grub/loopback.cfg"
    else
        echo "[GENERATOR] WARNING: loopback.cfg not found!"
    fi
    umount "$WORK_DIR/efi_mount"
fi

# 4. Rebuild ISO
echo "[GENERATOR] Rebuilding ISO..."
xorriso -as mkisofs \
  -r -V "Ubuntu-Autoinstall" \
  -o "$DESTINATION" \
  -J -l -cache-inodes \
  -isohybrid-mbr "$WORK_DIR/edit/isolinux/isohdpfx.bin" \
  -b isolinux/isolinux.bin \
     -c isolinux/boot.cat \
     -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e EFI/boot/bootx64.efi \
     -no-emul-boot \
  "$WORK_DIR/edit"

echo "[GENERATOR] Done! ISO saved as $DESTINATION"
