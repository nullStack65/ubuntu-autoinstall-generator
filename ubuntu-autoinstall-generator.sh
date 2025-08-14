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
            --http-server) PACKER_HTTP_IP="$2"; shift ;;
            --http-port) PACKER_HTTP_PORT="$2"; shift ;;
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
    local autoinstall_params="autoinstall ds=nocloud-net;s=http://$PACKER_HTTP_IP:$PACKER_HTTP_PORT/"
    local modified=false
    
    # Try multiple GRUB config locations
    local grub_configs=(
        "$WORKDIR/iso/boot/grub/grub.cfg"
        "$WORKDIR/iso/EFI/BOOT/grub.cfg" 
        "$WORKDIR/iso/boot/grub/loopback.cfg"
    )
    
    for grub_cfg in "${grub_configs[@]}"; do
        if [[ -f "$grub_cfg" ]]; then
            log "Modifying GRUB configuration: $(basename "$grub_cfg")"
            
            # Backup original
            cp "$grub_cfg" "${grub_cfg}.bak"
            
            # More precise modifications for different kernel patterns
            # Handle standard vmlinuz
            sed -i "s|linux\s*/casper/vmlinuz\s*---\s*|linux /casper/vmlinuz $autoinstall_params --- |g" "$grub_cfg"
            sed -i "s|linux\s*/casper/vmlinuz\s*$|linux /casper/vmlinuz $autoinstall_params|g" "$grub_cfg"
            
            # Handle HWE kernel
            sed -i "s|linux\s*/casper/hwe-vmlinuz\s*---\s*|linux /casper/hwe-vmlinuz $autoinstall_params --- |g" "$grub_cfg"
            sed -i "s|linux\s*/casper/hwe-vmlinuz\s*$|linux /casper/hwe-vmlinuz $autoinstall_params|g" "$grub_cfg"
            
            # Handle linuxefi variants
            sed -i "s|linuxefi\s*/casper/vmlinuz\s*---\s*|linuxefi /casper/vmlinuz $autoinstall_params --- |g" "$grub_cfg"
            sed -i "s|linuxefi\s*/casper/vmlinuz\s*$|linuxefi /casper/vmlinuz $autoinstall_params|g" "$grub_cfg"
            sed -i "s|linuxefi\s*/casper/hwe-vmlinuz\s*---\s*|linuxefi /casper/hwe-vmlinuz $autoinstall_params --- |g" "$grub_cfg"
            sed -i "s|linuxefi\s*/casper/hwe-vmlinuz\s*$|linuxefi /casper/hwe-vmlinuz $autoinstall_params|g" "$grub_cfg"
            
            # Clean up any double spaces that might have been created
            sed -i 's|  *| |g' "$grub_cfg"
            
            modified=true
            log "Added autoinstall parameters to $(basename "$grub_cfg")"
        fi
    done
    
    if [[ "$modified" == false ]]; then
        log "⚠️  No GRUB config files found in expected locations"
    fi
}

modify_isolinux_config() {
    local autoinstall_params="autoinstall ds=nocloud-net;s=http://$PACKER_HTTP_IP:$PACKER_HTTP_PORT/"
    local modified=false
    
    # Try multiple isolinux config locations
    local isolinux_configs=(
        "$WORKDIR/iso/isolinux/isolinux.cfg"
        "$WORKDIR/iso/isolinux/txt.cfg"
        "$WORKDIR/iso/syslinux/isolinux.cfg"
        "$WORKDIR/iso/syslinux/txt.cfg"
    )
    
    for config_file in "${isolinux_configs[@]}"; do
        if [[ -f "$config_file" ]]; then
            log "Modifying isolinux configuration: $(basename "$config_file")"
            cp "$config_file" "${config_file}.bak"
            sed -i "s|append\s*|append $autoinstall_params |g" "$config_file"
            modified=true
            log "Added autoinstall parameters to $(basename "$config_file")"
        fi
    done
    
    if [[ "$modified" == false ]]; then
        log "ℹ️  No isolinux config files found (normal for modern UEFI ISOs)"
    fi
}

modify_boot_configs() {
    log "Attempting to modify all boot configurations..."
    
    # Always try both GRUB and isolinux modifications
    # Modern ISOs may have GRUB only, older ones may have both
    modify_grub_config
    modify_isolinux_config
    
    # Additional check for any missed boot configs
    find "$WORKDIR/iso" -name "*.cfg" -path "*/boot/*" -o -name "*.cfg" -path "*/EFI/*" | while read -r cfg_file; do
        if [[ ! "$cfg_file" == *".bak" ]]; then
            log "Found additional boot config: $cfg_file"
            # You could add more specific modifications here if needed
        fi
    done
}

create_iso() {
    log "Creating new ISO with autoinstall parameters..."
    
    # Get original ISO volume label
    VOLUME_LABEL=$(xorriso -indev "$ISO" -report_about NOTE 2>/dev/null | grep "Volume id" | cut -d"'" -f2 || echo "Ubuntu")
    
    # Try to detect and preserve the original ISO boot structure
    local xorriso_cmd="xorriso -as mkisofs -r -V \"$VOLUME_LABEL\" -J -joliet-long -cache-inodes"
    
    # Check if EFI boot image exists
    if [[ -f "$WORKDIR/iso/boot/grub/efi.img" ]]; then
        log "Found EFI boot image, creating hybrid UEFI/BIOS ISO..."
        xorriso_cmd="$xorriso_cmd -eltorito-boot isolinux/isolinux.bin -eltorito-catalog isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table -eltorito-alt-boot -eltorito-platform efi -eltorito-boot boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat"
    elif [[ -f "$WORKDIR/iso/EFI/BOOT/bootx64.efi" ]]; then
        log "Found UEFI bootloader, creating UEFI ISO..."
        xorriso_cmd="$xorriso_cmd -eltorito-alt-boot -eltorito-platform efi -eltorito-boot EFI/BOOT/bootx64.efi -no-emul-boot"
    elif [[ -f "$WORKDIR/iso/isolinux/isolinux.bin" ]]; then
        log "Found isolinux, creating BIOS ISO..."
        xorriso_cmd="$xorriso_cmd -eltorito-boot isolinux/isolinux.bin -eltorito-catalog isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table"
    else
        log "⚠️  No specific boot method detected, using basic ISO creation..."
    fi
    
    # Execute the xorriso command
    eval "$xorriso_cmd -o \"$DEST\" \"$WORKDIR/iso/\"" 2>/dev/null || {
        log "⚠️  Standard ISO creation failed, trying alternative method..."
        # Fallback method
        xorriso -as mkisofs -r -V "$VOLUME_LABEL" -o "$DEST" "$WORKDIR/iso/" 2>/dev/null
    }
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
    --http-server <ip>      Packer HTTP server IP (default: 10.0.2.2)
    --http-port <port>      Packer HTTP server port (default: 8080)
    --help                  Show this help message

Environment Variables:
    PACKER_HTTP_IP          Packer HTTP server IP
    PACKER_HTTP_PORT        Packer HTTP server port

Examples:
    $0 ubuntu-20.04.6-live-server-amd64.iso
    $0 --source ubuntu.iso --destination custom-autoinstall.iso
    $0 --http-server 192.168.1.100 --http-port 8000 ubuntu.iso
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