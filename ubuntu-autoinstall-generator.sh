#!/bin/bash

set -e

# === CONFIG ===
WORKDIR="./iso_work"
ISO=""
DEST=""
VALIDATE_ONLY=false

# === FUNCTIONS ===

log() {
    echo -e "[$(date +'%H:%M:%S')] 🔹 $1"
}

error() {
    echo -e "[$(date +'%H:%M:%S')] ❌ $1" >&2
    exit 1
}

check_dependencies() {
    for cmd in xorriso grep awk; do
        command -v $cmd >/dev/null || error "Missing dependency: $cmd"
    done
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --source) ISO="$2"; shift ;;
            --destination) DEST="$2"; shift ;;
            --validate-only) VALIDATE_ONLY=true ;;
            *.iso) ISO="$1" ;;  # fallback for positional ISO
            *) error "Unknown argument: $1" ;;
        esac
        shift
    done

    [[ -f "$ISO" ]] || error "ISO file not found: $ISO"

    # Default destination if not set
    if [[ -z "$DEST" ]]; then
        BASENAME=$(basename "$ISO" .iso)
        DEST="${BASENAME}-autoinstall.iso"
    fi
}

extract_version() {
    mkdir -p "$WORKDIR"
    xorriso -osirrox on -indev "$ISO" -extract /.disk/info "$WORKDIR/info.txt" || return
    VERSION=$(grep -Eo '[0-9]{2}\.[0-9]{2}' "$WORKDIR/info.txt" | head -n1 || echo "Unknown")
    log "Detected Ubuntu version: ${VERSION:-Unknown}"
}

detect_structure() {
    xorriso -indev "$ISO" -find / -type f > "$WORKDIR/files.txt"

    if grep -q "casper/vmlinuz" "$WORKDIR/files.txt"; then
        FORMAT="Live Server"
    elif grep -q "boot/grub" "$WORKDIR/files.txt"; then
        FORMAT="GRUB EFI"
    elif grep -q "1-Boot-NoEmul.img" "$WORKDIR/files.txt"; then
        FORMAT="Legacy Boot"
    else
        FORMAT="Unknown"
    fi

    log "Detected ISO format: $FORMAT"
}

validate_iso() {
    extract_version
    detect_structure
    if $VALIDATE_ONLY; then
        log "Validation complete ✅"
        exit 0
    fi
}

build_output() {
    if [[ -f "$DEST" ]]; then
        log "Autoinstall ISO already exists at $DEST — skipping rebuild ✅"
        return
    fi

    log "Packaging ISO for format: $FORMAT"

    TMPDIR=$(mktemp -d)
    xorriso -osirrox on -indev "$ISO" -extract / "$TMPDIR"

    case "$FORMAT" in
        "GRUB EFI"|"Live Server")
            log "Injecting autoinstall and Packer HTTP kernel args..."
            GRUB_CFG="$TMPDIR/boot/grub/grub.cfg"
            if [[ -f "$GRUB_CFG" ]]; then
                sed -i 's@ ---@ autoinstall ds=nocloud-net\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ---@g' "$GRUB_CFG"
            else
                error "Could not find grub.cfg to patch."
            fi
            ;;
        "Legacy Boot")
            log "Injecting into isolinux/txt.cfg..."
            TXT_CFG=$(find "$TMPDIR" -name "txt.cfg" | head -n1)
            if [[ -f "$TXT_CFG" ]]; then
                sed -i 's@ ---@ autoinstall ds=nocloud-net\;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ---@g' "$TXT_CFG"
            else
                error "Could not find isolinux txt.cfg to patch."
            fi
            ;;
        *)
            error "Unsupported ISO format. Cannot proceed."
            ;;
    esac

    log "Rebuilding ISO..."
    xorriso -as mkisofs \
        -r -V "UBUNTU_AUTOINSTALL" \
        -o "$DEST" \
        -J -l -cache-inodes \
        -isohybrid-gpt-basdat \
        -partition_offset 16 \
        --grub2-mbr "$TMPDIR/boot/grub/i386-pc/boot_hybrid.img" \
        -append_partition 2 0xef "$TMPDIR/boot/grub/efi.img" \
        -appended_part_as_gpt \
        -c boot.catalog \
        -b boot/grub/i386-pc/eltorito.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        -eltorito-alt-boot \
        -e '--interval:appended_partition_2:all::' \
        -no-emul-boot \
        "$TMPDIR"


    rm -rf "$TMPDIR"
    log "Packaging complete 🎉"
    log "Output ISO: $DEST"
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
