#!/bin/bash

# Debug script to examine Ubuntu 22.04 ISO boot structure

ISO_SOURCE="/var/lib/vz/template/iso/ubuntu-22.04.4-live-server-amd64.iso"
MOUNT_POINT="/mnt/iso_debug"
WORK_DIR="./iso_debug_work"

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

cleanup() {
    echo -e "${GREEN}[DEBUG]${NC} Cleaning up..."
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT"
    fi
    if [[ -d "$MOUNT_POINT" ]]; then
        rmdir "$MOUNT_POINT"
    fi
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT

echo -e "${GREEN}[DEBUG]${NC} Analyzing Ubuntu 22.04 ISO boot structure..."

# 1. Mount the original ISO
echo -e "${GREEN}[DEBUG]${NC} 1. Mounting original ISO..."
mkdir -p "$MOUNT_POINT"
if ! mount -o loop,ro "$ISO_SOURCE" "$MOUNT_POINT"; then
    echo -e "${GREEN}[DEBUG]${NC} Failed to mount ISO"
    exit 1
fi

# 2. Extract boot information using xorriso
echo -e "${GREEN}[DEBUG]${NC} 2. Extracting boot information..."
mkdir -p "$WORK_DIR"

echo -e "${BLUE}--- xorriso boot info ---${NC}"
xorriso -indev "$ISO_SOURCE" -report_about NOTE 2>&1 | grep -E "(Boot record|Volume|El-Torito|EFI)"

echo -e "${BLUE}--- xorriso detailed boot analysis ---${NC}"
# No change needed here, it's already redirecting stderr
xorriso -indev "$ISO_SOURCE" -report_el_torito as_mkisofs 2>&1 | head -20

# 3. Look for all boot-related files
echo -e "${GREEN}[DEBUG]${NC} 3. Searching for boot files..."

echo -e "${BLUE}--- Boot directories and files ---${NC}"
find "$MOUNT_POINT" -type d \( -name "*boot*" -o -name "*grub*" -o -name "*efi*" -o -name "*isolinux*" \) 2>/dev/null | sort

echo -e "${BLUE}--- All .img files ---${NC}"
find "$MOUNT_POINT" -name "*.img" 2>/dev/null

echo -e "${BLUE}--- All .bin files ---${NC}"
find "$MOUNT_POINT" -name "*.bin" 2>/dev/null

echo -e "${BLUE}--- All boot config files ---${NC}"
find "$MOUNT_POINT" -name "*.cfg" 2>/dev/null

# 4. Check specific Ubuntu 22.04 boot locations
echo -e "${GREEN}[DEBUG]${NC} 4. Checking specific locations..."

locations=(
    "boot/grub/efi.img"
    "boot/grub/bios.img"  
    "EFI/boot/bootx64.efi"
    "EFI/ubuntu/grubx64.efi"
    "boot/grub/grub.cfg"
    "boot/grub/loopback.cfg"
    "isolinux/isolinux.bin"
    "isolinux/isolinux.cfg"
    "casper/vmlinuz"
    "casper/initrd"
)

for loc in "${locations[@]}"; do
    if [[ -f "$MOUNT_POINT/$loc" ]]; then
        size=$(stat -c%s "$MOUNT_POINT/$loc")
        echo -e "${GREEN}[DEBUG]${NC} ✓ Found: $loc (${size} bytes)"
    else
        echo -e "${YELLOW}[DEBUG]${NC} ✗ Missing: $loc"
    fi
done

# 5. Check directory structure
echo -e "${GREEN}[DEBUG]${NC} 5. Top-level directory structure..."
ls -la "$MOUNT_POINT/"

echo -e "${GREEN}[DEBUG]${NC} 6. Boot directory contents..."
if [[ -d "$MOUNT_POINT/boot" ]]; then
    # FIX: Redirect stderr to /dev/null to suppress harmless SIGPIPE messages
    find "$MOUNT_POINT/boot" -type f 2>/dev/null | head -20
else
    echo -e "${YELLOW}[DEBUG]${NC} No /boot directory found"
fi

echo -e "${GREEN}[DEBUG]${NC} 7. EFI directory contents..."
if [[ -d "$MOUNT_POINT/EFI" ]]; then
    # FIX: Redirect stderr to /dev/null
    find "$MOUNT_POINT/EFI" -type f 2>/dev/null | head -20
else
    echo -e "${YELLOW}[DEBUG]${NC} No /EFI directory found"
fi

# 8. Extract to work directory and check file permissions
echo -e "${GREEN}[DEBUG]${NC} 8. Extracting sample files for analysis..."
mkdir -p "$WORK_DIR/sample"

# Try to copy some key files
if [[ -f "$MOUNT_POINT/boot/grub/grub.cfg" ]]; then
    cp "$MOUNT_POINT/boot/grub/grub.cfg" "$WORK_DIR/sample/" 2>/dev/null
fi

if [[ -d "$MOUNT_POINT/boot" ]]; then
    # Check what boot files actually exist
    echo -e "${BLUE}--- All files in /boot ---${NC}"
    # FIX: Redirect stderr from find to suppress SIGPIPE errors from its '-exec' action
    find "$MOUNT_POINT/boot" -type f -exec ls -la {} \; 2>/dev/null | head -20
fi

echo -e "${GREEN}[DEBUG]${NC} Analysis complete. Check the output above to see what boot files are actually present."
