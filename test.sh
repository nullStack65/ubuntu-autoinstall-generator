#!/bin/bash

# --- Configuration ---
ISO_SOURCE="/var/lib/vz/template/iso/ubuntu-22.04.4-live-server-amd64.iso"
ISO_DESTINATION="/var/lib/vz/template/iso/ubuntu-22.04-autoinstall.iso"
PYTHON_SCRIPT="./ubuntu-autoinstall-generator/ubuntu-autoinstall-generator.py"
HTTP_SERVER="192.168.0.250"
HTTP_PORT="8000"
MOUNT_POINT="/mnt/iso_test"

# --- TUI Colors ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# --- Helper Functions ---
cleanup() {
    echo -e "${GREEN}[TEST.SH]${NC} Cleaning up..."
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount "$MOUNT_POINT"
    fi
    if [[ -d "$MOUNT_POINT" ]]; then
        rmdir "$MOUNT_POINT"
    fi
}

# Set up trap for cleanup on exit
trap cleanup EXIT

# --- Main Test Loop ---
echo -e "${GREEN}[TEST.SH]${NC} Starting automated test loop for Python autoinstall-generator..."

# 0. Run debug script first to analyze ISO structure
echo -e "${GREEN}[TEST.SH]${NC} 0. Analyzing source ISO boot structure with debug script..."
if [[ -f "./iso_debug.sh" ]]; then
    chmod +x "./iso_debug.sh"
    echo -e "${BLUE}[DEBUG]${NC} Running ISO structure analysis..."
    "./iso_debug.sh"
    echo -e "${BLUE}[DEBUG]${NC} Debug analysis complete."
    echo ""
    echo -e "${YELLOW}[TEST.SH]${NC} Press Enter to continue with the main test, or Ctrl+C to exit..."
    read -r
else
    echo -e "${YELLOW}[TEST.SH]${NC} Debug script not found, skipping structure analysis"
fi

# 1. Clean up previous runs and ensure the generator script is ready
echo -e "${GREEN}[TEST.SH]${NC} 1. Cleaning up and preparing the generator script..."
rm -rf ubuntu-autoinstall-generator
git clone git@github.com:nullStack65/ubuntu-autoinstall-generator.git || { 
    echo -e "${RED}[TEST.SH]${NC} Failed to clone repository."; 
    exit 1; 
}
rm -f "$ISO_DESTINATION"

# Check if Python script exists and make it executable
if [[ ! -f "$PYTHON_SCRIPT" ]]; then
    echo -e "${RED}[TEST.SH]${NC} Error: Python script not found at $PYTHON_SCRIPT"
    echo -e "${YELLOW}[TEST.SH]${NC} Looking for alternative script names..."
    
    # Try alternative names
    for alt_name in "ubuntu-autoinstall-generator.py" "ubuntu_autoinstall.py" "autoinstall_builder.py" "build_iso.py"; do
        alt_path="./ubuntu-autoinstall-generator/$alt_name"
        if [[ -f "$alt_path" ]]; then
            PYTHON_SCRIPT="$alt_path"
            echo -e "${GREEN}[TEST.SH]${NC} Found script at: $PYTHON_SCRIPT"
            break
        fi
    done
    
    if [[ ! -f "$PYTHON_SCRIPT" ]]; then
        echo -e "${RED}[TEST.SH]${NC} No Python script found. Exiting."
        exit 1
    fi
fi

chmod +x "$PYTHON_SCRIPT"

# Check if Python 3 is available
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}[TEST.SH]${NC} Error: Python 3 is not installed. Exiting."
    exit 1
fi

# Check if xorriso is available
if ! command -v xorriso &> /dev/null; then
    echo -e "${RED}[TEST.SH]${NC} Error: xorriso is not installed. Please install it:"
    echo -e "${YELLOW}[TEST.SH]${NC}   Ubuntu/Debian: sudo apt install xorriso"
    echo -e "${YELLOW}[TEST.SH]${NC}   CentOS/RHEL:   sudo yum install xorriso"
    exit 1
fi

# 2. Run the Python autoinstall generator
echo -e "${GREEN}[TEST.SH]${NC} 2. Running the Python autoinstall generator with test values..."
echo -e "${BLUE}[GENERATOR.PY]${NC} Starting subprocess..."

# Run with verbose output and capture both stdout and stderr
if python3 "$PYTHON_SCRIPT" \
    --source "$ISO_SOURCE" \
    --output "$ISO_DESTINATION" \
    --http-server "$HTTP_SERVER" \
    --http-port "$HTTP_PORT" \
    --verbose; then
    echo -e "${BLUE}[GENERATOR.PY]${NC} Subprocess finished successfully."
else
    echo -e "${RED}[GENERATOR.PY]${NC} Subprocess failed with exit code $?"
    exit 1
fi

# Check if the generated ISO exists
if [[ ! -f "$ISO_DESTINATION" ]]; then
    echo -e "${RED}[TEST.SH]${NC} Error: Autoinstall ISO was not created at $ISO_DESTINATION. Exiting."
    exit 1
fi

# Get file size for verification
ISO_SIZE=$(stat -c%s "$ISO_DESTINATION" 2>/dev/null || echo "0")
ISO_SIZE_MB=$((ISO_SIZE / 1024 / 1024))
echo -e "${GREEN}[TEST.SH]${NC} Generated ISO size: ${ISO_SIZE_MB} MB"

if [[ $ISO_SIZE_MB -lt 50 ]]; then
    echo -e "${YELLOW}[TEST.SH]${NC} Warning: Generated ISO seems small (${ISO_SIZE_MB} MB)"
fi

# 3. Mount the newly created ISO
echo -e "${GREEN}[TEST.SH]${NC} 3. Mounting the generated ISO to inspect boot configurations..."
mkdir -p "$MOUNT_POINT"

if ! mount -o loop,ro "$ISO_DESTINATION" "$MOUNT_POINT"; then
    echo -e "${RED}[TEST.SH]${NC} Error: Failed to mount the ISO. The file might be corrupted."
    exit 1
fi

echo -e "${GREEN}[TEST.SH]${NC} ISO mounted successfully at $MOUNT_POINT"

# 4. Verify ISO structure
echo -e "${GREEN}[TEST.SH]${NC} 4. Verifying ISO structure..."
if [[ -d "$MOUNT_POINT/boot/grub" ]]; then
    echo -e "${GREEN}[TEST.SH]${NC} ✅ GRUB boot directory found"
else
    echo -e "${RED}[TEST.SH]${NC} ❌ GRUB boot directory missing"
fi

if [[ -d "$MOUNT_POINT/casper" ]]; then
    echo -e "${GREEN}[TEST.SH]${NC} ✅ Casper directory found"
else
    echo -e "${RED}[TEST.SH]${NC} ❌ Casper directory missing"
fi

# 5. Check multiple boot configuration files
echo -e "${GREEN}[TEST.SH]${NC} 5. Checking boot configuration files..."

# Expected autoinstall parameter
EXPECTED_PARAM="autoinstall ds=nocloud-net;s=http://${HTTP_SERVER}:${HTTP_PORT}/"
SUCCESS_COUNT=0
TOTAL_CHECKS=0

# Check GRUB configs
for grub_file in "boot/grub/grub.cfg" "boot/grub/loopback.cfg" "EFI/BOOT/grub.cfg"; do
    if [[ -f "$MOUNT_POINT/$grub_file" ]]; then
        echo -e "${GREEN}[TEST.SH]${NC} Checking $grub_file..."
        ((TOTAL_CHECKS++))
        
        if grep -q "$EXPECTED_PARAM" "$MOUNT_POINT/$grub_file"; then
            echo -e "${GREEN}[TEST.SH]${NC} ✅ Autoinstall parameters found in $grub_file"
            ((SUCCESS_COUNT++))
            
            # Show the modified lines
            echo -e "${BLUE}[TEST.SH]${NC} Modified kernel lines in $grub_file:"
            grep -n "$EXPECTED_PARAM" "$MOUNT_POINT/$grub_file" | head -3
        else
            echo -e "${RED}[TEST.SH]${NC} ❌ Autoinstall parameters NOT found in $grub_file"
        fi
    else
        echo -e "${YELLOW}[TEST.SH]${NC} $grub_file not found (may be normal)"
    fi
done

# Check isolinux configs (if they exist)
for isolinux_file in "isolinux/isolinux.cfg" "isolinux/txt.cfg"; do
    if [[ -f "$MOUNT_POINT/$isolinux_file" ]]; then
        echo -e "${GREEN}[TEST.SH]${NC} Checking $isolinux_file..."
        ((TOTAL_CHECKS++))
        
        if grep -q "$EXPECTED_PARAM" "$MOUNT_POINT/$isolinux_file"; then
            echo -e "${GREEN}[TEST.SH]${NC} ✅ Autoinstall parameters found in $isolinux_file"
            ((SUCCESS_COUNT++))
        else
            echo -e "${RED}[TEST.SH]${NC} ❌ Autoinstall parameters NOT found in $isolinux_file"
        fi
    fi
done

# 6. Display one complete grub.cfg for manual inspection
echo -e "${GREEN}[TEST.SH]${NC} 6. Sample of main grub.cfg content:"
if [[ -f "$MOUNT_POINT/boot/grub/grub.cfg" ]]; then
    echo -e "${BLUE}--- boot/grub/grub.cfg (first 50 lines) ---${NC}"
    head -50 "$MOUNT_POINT/boot/grub/grub.cfg"
    echo -e "${BLUE}--- End of sample ---${NC}"
else
    echo -e "${RED}[TEST.SH]${NC} Main grub.cfg not found"
fi

# 7. Final results
echo -e "${GREEN}[TEST.SH]${NC} 7. Test Results Summary:"
if [[ $SUCCESS_COUNT -gt 0 ]]; then
    echo -e "${GREEN}[TEST.SH]${NC} ✅ SUCCESS! Autoinstall parameters found in $SUCCESS_COUNT out of $TOTAL_CHECKS boot configuration files."
    echo -e "${GREEN}[TEST.SH]${NC} The modified ISO should work for autoinstall with:"
    echo -e "${GREEN}[TEST.SH]${NC}   HTTP Server: http://${HTTP_SERVER}:${HTTP_PORT}/"
    echo -e "${GREEN}[TEST.SH]${NC}   Required files: user-data, meta-data"
else
    if [[ $TOTAL_CHECKS -eq 0 ]]; then
        echo -e "${YELLOW}[TEST.SH]${NC} ⚠️  WARNING! No boot configuration files found to check."
    else
        echo -e "${RED}[TEST.SH]${NC} ❌ FAILURE! Autoinstall parameters were NOT found in any of the $TOTAL_CHECKS boot configuration files."
    fi
fi

# 8. Additional verification - check if ISO is bootable
echo -e "${GREEN}[TEST.SH]${NC} 8. Checking if ISO is bootable..."
if xorriso -indev "$ISO_DESTINATION" -report_about NOTE 2>/dev/null | grep -q "Boot record"; then
    echo -e "${GREEN}[TEST.SH]${NC} ✅ ISO appears to have boot records"
else
    echo -e "${YELLOW}[TEST.SH]${NC} ⚠️  Could not verify boot records"
fi

echo -e "${GREEN}[TEST.SH]${NC} Test completed. Check the results above."

# Note: cleanup() will be called automatically via trap