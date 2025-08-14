#!/bin/bash
set -Eeuo pipefail

function log() {
    echo >&2 -e "[$(date +"%Y-%m-%d %H:%M:%S")] ${1-}"
}

function die() {
    log "💥 $1"
    exit 1
}

function usage() {
    cat << 'EOF'
Ubuntu Autoinstall ISO Builder

USAGE:
    $0 --source <source.iso> --destination <output.iso> [OPTIONS]

REQUIRED:
    --source <file>        Source Ubuntu ISO file
    --destination <file>   Output autoinstall ISO file

OPTIONS:
    --user-data <file>     Cloud-init user-data file to embed
    --meta-data <file>     Cloud-init meta-data file to embed
    --volume-label <name>  Custom volume label (default: ubuntu-autoinstall)
    --dry-run             Show what would be done without creating ISO
    --help                Show this help message

EXAMPLES:
    # Basic autoinstall ISO (requires external cloud-init data)
    $0 --source ubuntu-22.04-live-server-amd64.iso --destination ubuntu-auto.iso

    # Embed cloud-init configuration
    $0 --source ubuntu.iso --destination ubuntu-auto.iso --user-data user-data --meta-data meta-data

    # Test what would be done
    $0 --source ubuntu.iso --destination ubuntu-auto.iso --dry-run
EOF
    exit "${1:-0}"
}

# === Parse Arguments ===
SOURCE=""
DEST=""
USER_DATA=""
META_DATA=""
VOLUME_LABEL="ubuntu-autoinstall"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source) SOURCE="$2"; shift 2 ;;
        --destination) DEST="$2"; shift 2 ;;
        --user-data) USER_DATA="$2"; shift 2 ;;
        --meta-data) META_DATA="$2"; shift 2 ;;
        --volume-label) VOLUME_LABEL="$2"; shift 2 ;;
        --help) usage 0 ;;
        *) log "Unknown option: $1"; usage 1 ;;
    esac
done

# === Validation ===
[[ -z "$SOURCE" || -z "$DEST" ]] && usage 1
[[ ! -f "$SOURCE" ]] && die "Source ISO not found: $SOURCE"
[[ -n "$USER_DATA" && ! -f "$USER_DATA" ]] && die "user-data file not found: $USER_DATA"
[[ -n "$META_DATA" && ! -f "$META_DATA" ]] && die "meta-data file not found: $META_DATA"

# === Setup ===
TMPDIR=$(mktemp -d)
log "📁 Created temp dir: $TMPDIR"

# Extract ISO
log "📦 Extracting ISO contents..."
xorriso -osirrox on -indev "$SOURCE" -extract / "$TMPDIR" &>/dev/null
chmod -R u+w "$TMPDIR"
rm -rf "$TMPDIR/"'[BOOT]'

# === Validate Ubuntu ISO ===
[[ ! -f "$TMPDIR/casper/vmlinuz" ]] && die "Not a Ubuntu live ISO (missing casper/vmlinuz)"
[[ ! -f "$TMPDIR/.disk/info" ]] && die "Not a Ubuntu ISO (missing .disk/info)"
grep -qi "ubuntu" "$TMPDIR/.disk/info" || die "Not a Ubuntu ISO"
log "✅ Validated Ubuntu ISO"

# === Modify GRUB configs ===
GRUB_CONFIGS=("grub.cfg" "loopback.cfg")
for cfg in "${GRUB_CONFIGS[@]}"; do
    GRUB_PATH="$TMPDIR/boot/grub/$cfg"
    [[ ! -f "$GRUB_PATH" ]] && continue
    
    # Count matching menu entries before modification
    MATCHES=$(grep -c "menuentry.*Install Ubuntu" "$GRUB_PATH" || echo "0")
    
    # Add autoinstall parameter to Ubuntu install entries only
    sed -i '/menuentry.*Install Ubuntu/,/}/ s|linux[[:space:]]*/casper/vmlinuz|& autoinstall|' "$GRUB_PATH"
    
    log "🧩 Added autoinstall to $MATCHES menu entries in $cfg"
done

# === Optionally embed cloud-init ===
if [[ -n "$USER_DATA" ]]; then
    mkdir -p "$TMPDIR/nocloud"
    cp "$USER_DATA" "$TMPDIR/nocloud/user-data"
    if [[ -n "$META_DATA" ]]; then
        cp "$META_DATA" "$TMPDIR/nocloud/meta-data"
    else
        touch "$TMPDIR/nocloud/meta-data"
    fi
    log "📁 Embedded cloud-init data in /nocloud/"
    
    # Add cloud-init data source to GRUB configs
    for cfg in "${GRUB_CONFIGS[@]}"; do
        GRUB_PATH="$TMPDIR/boot/grub/$cfg"
        [[ ! -f "$GRUB_PATH" ]] && continue
        
        # Add nocloud data source to autoinstall entries
        sed -i '/menuentry.*Install Ubuntu/,/}/ s|autoinstall|& ds=nocloud\\;s=/cdrom/nocloud/|' "$GRUB_PATH"
        log "🔗 Added nocloud data source to $cfg"
    done
fi

# === Repackage ISO ===
log "🔨 Creating autoinstall ISO..."
cd "$TMPDIR"
xorriso -as mkisofs \
    -r -V "$VOLUME_LABEL" \
    -J -joliet-long \
    -e boot/grub/efi.img \
    -no-emul-boot \
    -isohybrid-gpt-basdat \
    -o "../$DEST" . &>/dev/null
cd - &>/dev/null
log "✅ Created autoinstall ISO: $DEST"

# === Cleanup ===
rm -rf "$TMPDIR"
log "🧹 Cleaned up temp dir"