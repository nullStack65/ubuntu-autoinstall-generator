#!/bin/bash

set -e

# === CONFIG ===
WORKDIR="./iso_work"
OUTPUT="./output"
ISO=""
DEST=""
VALIDATE_ONLY=false

# === ARG PARSING ===
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

extract_version() {
    mkdir -p "$WORKDIR"
    xorriso -osirrox on -indev "$ISO" -extract /.disk/info "$WORKDIR/info.txt" || return
    VERSION=$(grep -oP 'Ubuntu \K[0-9]+\.[0-9]+' "$WORKDIR/info.txt" || echo "Unknown")
    log "Detected Ubuntu version: $VERSION"
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
    mkdir -p "$OUTPUT"
    log "Packaging ISO for format: $FORMAT"
    
    # Create temporary directory for extraction
    local temp_dir=$(mktemp -d)
    
    # Extract ISO contents to temp_dir
    xorriso -osirrox on -indev "$ISO" -extract / "$temp_dir" || error "Failed to extract ISO"
    
    # Example modification: Adding autoinstall parameter
    # Edit the grub.cfg or isolinux/txt.cfg file to add "autoinstall" to the boot parameters
    # This part requires specific knowledge of the bootloader's configuration format.
    
    # Example: Copy autoinstall files
    # mkdir -p "$temp_dir/autoinstall"
    # cp "$autoinstall_files/user-data" "$temp_dir/autoinstall/"
    # cp "$autoinstall_files/meta-data" "$temp_dir/autoinstall/"
    
    # Create the new ISO with xorriso
    xorriso -as mkisofs \
        -r -V "Ubuntu-autoinstall" \
        -o "$DEST" \
        -J -l -b isolinux/isolinux.bin \
        -c isolinux/boot.cat -no-emul-boot \
        -boot-load-size 4 -boot-info-table \
        --grub2-boot-info \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$temp_dir" || error "Failed to create new ISO"
    
    # Clean up
    rm -rf "$temp_dir"
    
    log "Packaging complete 🎉"
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
