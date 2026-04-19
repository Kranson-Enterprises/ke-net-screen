#!/bin/bash
set -e  # Exit immediately if a command exits with a non-zero status.
set -u  # Treat unset variables as an error when substituting.
set -o pipefail  # Prevent errors in a pipeline from being masked.
# set -x  # Print each command before executing it.

IFS=$'\n\t' # Set the Internal Field Separator to newline and tab.

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR" && pwd)"
LAYER="$SCRIPT_DIR/layer/ke-00-layer.yaml"
LAYER_CONFIG="ke-net-screen.yaml"

# Tell user to insert the SD card and warn it will be erased
read -p "Insert the SD card before continuing...it will be erased!"

# Check if the required commands are available
for cmd in git sudo fdisk parted mkfs dd rpi-imager; do
  if ! command -v $cmd &> /dev/null; then
    echo "Error: $cmd is not installed. Please install it and try again."
    exit 1
  fi
done

# Tell user to insert the SD card and warn it will be erased
# read -p "Insert the SD card before continuing...it will be erased!"

# Show available devices
echo "-------------------------------------------------------------------------"
echo "Available devices:"
lsblk -d -o NAME,SIZE,MODEL,TYPE | grep disk
echo "-------------------------------------------------------------------------"
echo "WARNING: All data on the selected device will be erased!"
echo "Please ensure you have selected the correct device."
echo "If you are unsure, please check the output of 'lsblk' above."
echo "You can also use 'lsblk -f' to see the filesystem type and mount points."
echo "If you are sure, please proceed with the next steps."
echo "If you are not sure, please abort the script and check the device path."
echo "-------------------------------------------------------------------------"
echo ""

# Prompt for device
read -p "Enter the device path for the SD card (e.g., /dev/mmcblk0): " SD_DEVICE
SD_DEVICE=${SD_DEVICE:-/dev/mmcblk0}
# Check if the device exists
if [[ ! -b "$SD_DEVICE" ]]; then
  echo "Error: $SD_DEVICE is not a valid block device."
  exit 1
fi

# echo "WARNING: All data on $SD_DEVICE will be erased!"
# read -p "Type 'YES' to continue: " CONFIRM
# if [[ "$CONFIRM" != "YES" ]]; then
#   echo "Aborted."
#   exit 1
# fi

# read -t 5 -p "I am going to wait for 5 seconds before deleting target device contents ..."

echo "Deleting contents of SD with DD"
# This writes the first 34 blocks (17KB) of zeros to the SD card to clear partition table
sudo dd if=/dev/zero of=/dev/mmcblk0 bs=512 count=34 status=progress

# This would wipe the entire SD card, uncomment with caution, it can take a long time
# sudo dd if=/dev/zero of=/dev/mmcblk0 status=progress
if [[ $? -ne 0 ]]; then
  echo "dd failed!"
  exit 1
fi

# echo "Creating partition table"
# sudo mkfs -t vfat "$SD_DEVICE"
# if [[ $? -ne 0 ]]; then
#   echo "mkfs failed!"
#   exit 1
# fi
# sudo parted "$SD_DEVICE" mklabel msdos
# if [[ $? -ne 0 ]]; then
#   echo "parted failed!"
#   exit 1
# fi
# sudo parted "$SD_DEVICE" mkpart primary fat32 0% 100%
# if [[ $? -ne 0 ]]; then
#   echo "parted failed!"
#   exit 1
# fi
# sudo parted "$SD_DEVICE" set 1 lba on
# if [[ $? -ne 0 ]]; then
#   echo "parted failed!"
#   exit 1
# fi
# sudo parted "$SD_DEVICE" set 1 msdos on
# if [[ $? -ne 0 ]]; then
#   echo "parted failed!"
#   exit 1
# fi

echo "Target device is $SD_DEVICE"

# Change to the submodule hosting the rpi-image-gen tool
cd "$PROJECT_ROOT/rpi-image-gen"

./rpi-image-gen metadata --lint "$LAYER"

# Remove the existing work directory inside rpi-image-gen
# This is the working directory for the default build process
# sudo rm -Rf work

# Define output directory for the built image
# Use current script name minus .sh with -build suffix for output
OUTDIR="$PROJECT_ROOT/$(basename "$0" .sh)-build"
# Clean up any existing output directory
echo "Cleaning up existing output directory at $OUTDIR"
sudo rm -Rf "$OUTDIR"
sleep 2
mkdir -p "$OUTDIR"

# skip invoking syft
export IGconf_sbom_enable=n
# apt_cachedir="$SCRIPT_DIR/apt-cache"
# mkdir -p "$apt_cachedir"
# Execute with the options file
./rpi-image-gen build -S "$SCRIPT_DIR" -c "$LAYER_CONFIG" -B "$OUTDIR"

sleep 2

cd "$PROJECT_ROOT"

# sudo rpi-imager --cli "$OUTDIR/image-deb13-arm64-splash/deb13-arm64-splash.img" /dev/mmcblk0

# sudo rpi-imager --cli --disable-verify --disable-eject "$OUTDIR/image-deb13-arm64-splash/deb13-arm64-splash.img" /dev/mmcblk0

sudo rpi-imager --cli --disable-verify "$OUTDIR/image-deb13-arm64-splash/deb13-arm64-splash.img" /dev/mmcblk0

echo "SD card setup complete."