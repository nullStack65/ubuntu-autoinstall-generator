#!/bin/bash

set -e

# === CONFIG ===
WORKDIR="./iso_work"
ISO=""
DEST=""
VALIDATE_ONLY=false
PACKER_HTTP_IP="${PACKER_HTTP_IP:-10.0.2.2}"
PACKER_HTTP_PORT="${PACKER_HTTP_PORT:-8080}"

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
            --packer-ip) PACKER_HTTP_IP="$2"; shift ;;
            --packer-port) PACKER_HTTP_PORT="$2"; shift ;;
            *.iso) ISO="$1" ;;
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
    xorriso -osirrox on -indev "$ISO" -extract /.disk/info "$WORKDIR/info.txt" 2>/dev/null || return
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

extract_iso() {
    log "Extracting ISO contents..."
    mkdir -p "$WORKDIR/iso"
    xorriso -osirrox on -indev "$ISO" -extract / "$WORKDIR/iso/" 2>/dev/null
    
    # Make files writable
    chmod -R u+w "$WORKDIR/iso/"
}

modify_grub_config() {
    local grub_cfg="$WORKDIR/iso/boot/grub/grub.cfg"
    local autoinstall_params="autoinstall ds=nocloud-net\\;s=http://$PACKER_HTTP_IP:$PACKER_HTTP_PORT/"
    
    if [[ -f "$grub_cfg" ]]; then
        log "Modifying GRUB configuration..."
        
        # Backup original
        cp "$grub_cfg" "$grub_cfg.bak"
        
        # Modify kernel parameters in GRUB config
        sed -i "s|linux\s*/casper/vmlinuz|linux /casper/vmlinuz $autoinstall_params|g" "$grub_cfg"
        sed -i "s|linuxefi\s*/casper/vmlinuz|linuxefi /casper/vmlinuz $autoinstall_params|g" "$grub_cfg"
        
        log "Added autoinstall parameters to GRUB config"
    else
        log "⚠️  GRUB config not found, skipping GRUB modification"
    fi
}

modify_isolinux_config() {
    local isolinux_cfg="$WORKDIR/iso/isolinux/isolinux.cfg"
    local txt_cfg="$WORKDIR/iso/isolinux/txt.cfg"
    local autoinstall_params="autoinstall ds=nocloud-net;s=http://$PACKER_HTTP_IP:$PACKER_HTTP_PORT/"
    
    # Try isolinux.cfg first
    if [[ -f "$isolinux_cfg" ]]; then
        log "Modifying isolinux configuration..."
        cp "$isolinux_cfg" "$isolinux_cfg.bak"
        sed -i "s|append\s*|append $autoinstall_params |g" "$isolinux_cfg"
        log "Added autoinstall parameters to isolinux config"
    fi
    
    # Also try txt.cfg which is common in Ubuntu ISOs
    if [[ -f "$txt_cfg" ]]; then
        log "Modifying txt.cfg configuration..."
        cp "$txt_cfg" "$txt_cfg.bak"
        sed -i "s|append\s*|append $autoinstall_params |g" "$txt_cfg"
        log "Added autoinstall parameters to txt.cfg"
    fi
    
    if [[ ! -f "$isolinux_cfg" && ! -f "$txt_cfg" ]]; then
        log "⚠️  No isolinux config files found, skipping isolinux modification"
    fi
}

modify_boot_configs() {
    case "$FORMAT" in
        "Live Server"|"GRUB EFI")
            modify_grub_config
            modify_isolinux_config  # Many ISOs have both
            ;;
        "Legacy Boot")
            modify_isolinux_config
            ;;
        *)
            error "Unsupported ISO format for modification"
            ;;
    esac
}

create_iso() {
    log "Creating new ISO with autoinstall parameters..."
    
    # Get original ISO volume label
    VOLUME_LABEL=$(xorriso -indev "$ISO" -report_about NOTE 2>/dev/null | grep "Volume id" | cut -d"'" -f2 || echo "Ubuntu")
    
    case "$FORMAT" in
        "Live Server"|"GRUB EFI")
            # Create hybrid ISO with both BIOS and UEFI support
            xorriso -as mkisofs \
                -r -V "$VOLUME_LABEL" \
                -J -joliet-long \
                -cache-inodes \
                -b isolinux/isolinux.bin \
                -c isolinux/boot.cat \
                -no-emul-boot \
                -boot-load-size 4 \
                -boot-info-table \
                -eltorito-alt-boot \
                -e boot/grub/efi.img \
                -no-emul-boot \
                -isohybrid-gpt-basdat \
                -o "$DEST" \
                "$WORKDIR/iso/" 2>/dev/null
            ;;
        "Legacy Boot")
            # Create BIOS-only ISO
            xorriso -as mkisofs \
                -r -V "$VOLUME_LABEL" \
                -J -joliet-long \
                -cache-inodes \
                -b isolinux/isolinux.bin \
                -c isolinux/boot.cat \
                -no-emul-boot \
                -boot-load-size 4 \
                -boot-info-table \
                -o "$DEST" \
                "$WORKDIR/iso/" 2>/dev/null
            ;;
    esac
}

build_output() {
    if [[ -f "$DEST" ]]; then
        log "Autoinstall ISO already exists at $DEST — skipping rebuild ✅"
        return
    fi

    log "Building autoinstall ISO for format: $FORMAT"
    log "Packer HTTP server: $PACKER_HTTP_IP:$PACKER_HTTP_PORT"

    extract_iso
    modify_boot_configs
    create_iso

    log "Packaging complete 🎉"
    log "Output ISO: $DEST"
    log "The ISO will fetch user-data from: http://$PACKER_HTTP_IP:$PACKER_HTTP_PORT/user-data"
}

cleanup() {
    rm -rf "$WORKDIR"
}

show_help() {
    cat << EOF
Usage: $0 [OPTIONS] <iso_file>

Options:
    --source <file>         Source ISO file
    --destination <file>    Output ISO file (default: <source>-autoinstall.iso)
    --validate-only         Only validate the ISO, don't create output
    --packer-ip <ip>        Packer HTTP server IP (default: 10.0.2.2)
    --packer-port <port>    Packer HTTP server port (default: 8080)
    --help                  Show this help message

Environment Variables:
    PACKER_HTTP_IP          Packer HTTP server IP
    PACKER_HTTP_PORT        Packer HTTP server port

Examples:
    $0 ubuntu-20.04.6-live-server-amd64.iso
    $0 --source ubuntu.iso --destination custom-autoinstall.iso
    $0 --packer-ip 192.168.1.100 --packer-port 8000 ubuntu.iso
    PACKER_HTTP_IP=10.0.0.1 $0 ubuntu.iso
EOF
}

# === MAIN ===

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    show_help
    exit 0
fi

check_dependencies
parse_args "$@"
validate_iso
build_output
cleanup