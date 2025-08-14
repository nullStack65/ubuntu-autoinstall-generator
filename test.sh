#!/bin/bash

# --- Configuration ---
ISO_SOURCE="/var/lib/vz/template/iso/ubuntu-22.04.4-live-server-amd64.iso"
ISO_DESTINATION="/var/lib/vz/template/iso/ubuntu-22.04-autoinstall.iso"
GENERATOR_SCRIPT="./ubuntu-autoinstall-generator/ubuntu-autoinstall-generator.sh"
HTTP_SERVER="192.168.0.250"
HTTP_PORT="8000"
MOUNT_POINT="/mnt/iso_test"

# --- TUI Colors ---
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Main Test Loop ---
echo -e "${GREEN}[TEST.SH]${NC} Starting automated test loop for autoinstall-generator..."

# 1. Clean up previous runs and ensure the generator script is ready
echo -e "${GREEN}[TEST.SH]${NC} 1. Cleaning up and preparing the generator script..."
rm -rf ubuntu-autoinstall-generator
git clone git@github.com:nullStack65/ubuntu-autoinstall-generator.git || { echo -e "${GREEN}[TEST.SH]${NC} Failed to clone repository."; exit 1; }
rm -f "$ISO_DESTINATION"

# 2. Run the autoinstall generator
echo -e "${GREEN}[TEST.SH]${NC} 2. Running the autoinstall generator with test values..."
echo -e "${BLUE}[GENERATOR.SH]${NC} Starting subprocess..."
"$GENERATOR_SCRIPT" \
  --source "$ISO_SOURCE" \
  --destination "$ISO_DESTINATION" \
  --http-server "$HTTP_SERVER" \
  --http-port "$HTTP_PORT"
echo -e "${BLUE}[GENERATOR.SH]${NC} Subprocess finished."

# Check if the generated ISO exists
if [[ ! -f "$ISO_DESTINATION" ]]; then
  echo -e "${GREEN}[TEST.SH]${NC} Error: Autoinstall ISO was not created. Exiting."
  exit 1
fi

# 3. Mount the newly created ISO
echo -e "${GREEN}[TEST.SH]${NC} 3. Mounting the generated ISO to inspect grub.cfg..."
mkdir -p "$MOUNT_POINT"
mount -o loop,ro "$ISO_DESTINATION" "$MOUNT_POINT"

if [[ $? -ne 0 ]]; then
  echo -e "${GREEN}[TEST.SH]${NC} Error: Failed to mount the ISO. Exiting."
  cleanup
  exit 1
fi

# 4. Read and display the grub.cfg file
echo -e "${GREEN}[TEST.SH]${NC} 4. Contents of grub.cfg:"
cat "$MOUNT_POINT/boot/grub/grub.cfg"

# 5. Check for the autoinstall parameters
echo -e "${GREEN}[TEST.SH]${NC} 5. Verifying autoinstall parameters..."
if grep -q "autoinstall ds=nocloud-net;s=http://${HTTP_SERVER}:${HTTP_PORT}/" "$MOUNT_POINT/boot/grub/grub.cfg"; then
  echo -e "${GREEN}[TEST.SH]${NC} ✅ Success! The autoinstall parameters were correctly injected."
else
  echo -e "${GREEN}[TEST.SH]${NC} ❌ Failure! The autoinstall parameters were NOT found in grub.cfg."
fi

# 6. Clean up
echo -e "${GREEN}[TEST.SH]${NC} 6. Cleaning up..."
umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
echo -e "${GREEN}[TEST.SH]${NC} Test loop finished."