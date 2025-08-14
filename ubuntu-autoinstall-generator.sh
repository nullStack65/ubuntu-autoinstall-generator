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
    for cmd in xorriso grep awk sed; do
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

inject_kernel_args() {
    log "Injecting autoinstall kernel parameters..."

    mkdir -p "$WORKDIR/iso"
    xorriso -osirrox on -indev "$ISO" -extract / "$WORKDIR/iso"

    GRUB_CFG="$WORKDIR/iso/boot/grub/grub.cfg"
    if [[ -f "$GRUB_CFG" ]]; then
        sed -i '/linux / s/$/ autoinstall ds=nocloud-net;s=http:\/\/{{ .HTTPIP }}:{{ .HTTPPort }}\//' "$GRUB_CFG"
        log "Kernel parameters injected into grub.cfg"
    else
        error "Could not find grub.cfg to inject kernel parameters"
    fi
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

    case "$FORMAT" in
        "Live Server")
            inject_kernel_args
            xorriso -as mkisofs -o "$DEST" \
                -iso-level 3 \
                -full-iso9660-filenames \
                -volid "Ubuntu-Autoinstall" \
                -eltorito-boot boot/grub/i386-pc/eltorito.img \
                -no-emul-boot -boot-load-size 4 -boot-info-table \
                -eltorito-alt-boot -e boot/grub/efi.img \
                -no-emul-boot -isohybrid-gpt-basdat \
                "$WORKDIR/iso"
            ;;
        "Legacy Boot")
            cp "$ISO" "$DEST"
            ;;
        "GRUB EFI")
            cp "$ISO" "$DEST"
            ;;
        *)
            error "Unsupported ISO format. Cannot proceed."
            ;;
    esac

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
