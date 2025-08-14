#!/bin/bash

set -e

# === CONFIG ===
WORKDIR="./iso_work"
OUTPUT="./output"
ISO="$1"
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
            --validate-only) VALIDATE_ONLY=true ;;
            *.iso) ISO="$1" ;;
            *) error "Unknown argument: $1" ;;
        esac
        shift
    done

    [[ -f "$ISO" ]] || error "ISO file not found: $ISO"
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

    case "$FORMAT" in
        "Live Server")
            log "Using casper-based packaging..."
            # Insert packaging logic here
            ;;
        "GRUB EFI")
            log "Using GRUB EFI packaging..."
            # Insert packaging logic here
            ;;
        "Legacy Boot")
            log "Using legacy boot packaging..."
            # Insert packaging logic here
            ;;
        *)
            error "Unsupported ISO format. Cannot proceed."
            ;;
    esac

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
