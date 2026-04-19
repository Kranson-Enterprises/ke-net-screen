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
DEFAULT_SD_DEVICE="/dev/mmcblk0"
ENV_FILE="$PROJECT_ROOT/.env"
BUILD_ONLY=0
PREFLIGHT_ONLY=0
MIN_FREE_MB=12288

resolve_build_user_pubkey() {
  if [[ -n "${SSH_PUBKEY_USER1:-}" ]]; then
    return 0
  fi

  local build_user="${SUDO_USER:-${USER:-}}"
  local build_home=""
  local key_path=""

  if [[ -n "$build_user" ]]; then
    build_home=$(getent passwd "$build_user" | cut -d: -f6)
  fi

  if [[ -z "$build_home" ]]; then
    build_home="${HOME:-}"
  fi

  key_path="$build_home/.ssh/id_ed25519.pub"

  if [[ -z "$build_home" || ! -f "$key_path" ]]; then
    echo "Error: SSH public key for build user is missing: $key_path"
    echo "Create one with:"
    echo "  ssh-keygen -t ed25519 -a 100 -f \"$build_home/.ssh/id_ed25519\" -C \"${build_user:-localadmin}@$(hostname -s)\""
    echo "Then re-run this script."
    return 1
  fi

  SSH_PUBKEY_USER1="$(< "$key_path")"
  export SSH_PUBKEY_USER1

  return 0
}

usage() {
  cat <<'EOF'
Usage: ./ke-net-screen.sh [option]

Options:
  --preflight   Run prerequisite checks only and exit.
  --build-only  Build image artifacts without writing to an SD card.
  --help        Show this help text.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preflight)
      PREFLIGHT_ONLY=1
      shift
      ;;
    --build-only)
      BUILD_ONLY=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -f "$ENV_FILE" ]]; then
  echo "Loading environment from $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

require_commands() {
  local commands=(git sudo fdisk parted mkfs dd lsblk)
  if [[ $BUILD_ONLY -eq 0 && $PREFLIGHT_ONLY -eq 0 ]]; then
    commands+=(rpi-imager)
  fi

  for cmd in "${commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Error: $cmd is not installed. Please install it and try again."
      return 1
    fi
  done

  return 0
}

check_prereqs() {
  resolve_build_user_pubkey || return 1

  require_commands || return 1

  if [[ ! -x "$PROJECT_ROOT/rpi-image-gen/rpi-image-gen" ]]; then
    echo "Error: rpi-image-gen tool is missing at $PROJECT_ROOT/rpi-image-gen/rpi-image-gen"
    echo "Run: git submodule init && git submodule update"
    return 1
  fi

  if [[ ! -f "$PROJECT_ROOT/config/$LAYER_CONFIG" ]]; then
    echo "Error: missing config file $PROJECT_ROOT/config/$LAYER_CONFIG"
    return 1
  fi

  if [[ -z "${PIHOLE_PASSWORD:-}" ]]; then
    echo "Error: PIHOLE_PASSWORD is not set."
    echo "Set it in your shell or create $ENV_FILE from .env.example."
    return 1
  fi

  local free_mb
  free_mb=$(df -Pm "$PROJECT_ROOT" | awk 'NR==2 {print $4}')
  if [[ -z "$free_mb" || "$free_mb" -lt "$MIN_FREE_MB" ]]; then
    echo "Error: at least ${MIN_FREE_MB}MB free disk space is required in $PROJECT_ROOT."
    echo "Available: ${free_mb:-unknown}MB"
    return 1
  fi

  if ! getent hosts deb.debian.org >/dev/null 2>&1; then
    echo "Warning: deb.debian.org could not be resolved. Build may fail without internet access."
  fi

  return 0
}

if ! check_prereqs; then
  exit 1
fi

if [[ $PREFLIGHT_ONLY -eq 1 ]]; then
  echo "Preflight checks passed."
  exit 0
fi

# Tell user to insert the SD card and warn it will be erased
# read -p "Insert the SD card before continuing...it will be erased!"

if [[ $BUILD_ONLY -eq 0 ]]; then
  # Show available devices only when flashing is requested.
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

  # Tell user to insert the SD card and warn it will be erased
  read -p "Insert the SD card before continuing...it will be erased!"

  # Prompt for device
  read -p "Enter the device path for the SD card (e.g., /dev/mmcblk0): " SD_DEVICE
  SD_DEVICE=${SD_DEVICE:-$DEFAULT_SD_DEVICE}
  if [[ ! -b "$SD_DEVICE" ]]; then
    echo "Warning: $SD_DEVICE is not a valid block device. Skipping SD card write."
    BUILD_ONLY=1
  else
    MOUNTED_PARTITIONS="$(lsblk -nr -o MOUNTPOINT "$SD_DEVICE" | sed '/^$/d' || true)"
    if [[ -n "$MOUNTED_PARTITIONS" ]]; then
      echo "Error: $SD_DEVICE has mounted partitions. Unmount before continuing:"
      echo "$MOUNTED_PARTITIONS"
      # exit 1
    fi

    echo "WARNING: About to erase and overwrite $SD_DEVICE"
    read -p "Type the exact device path to confirm: " CONFIRM_DEVICE
    if [[ "$CONFIRM_DEVICE" != "$SD_DEVICE" ]]; then
      echo "Aborted: confirmation did not match selected device."
      exit 1
    fi

    echo "Deleting contents of SD with DD"
    # This writes the first 34 blocks (17KB) of zeros to the SD card to clear partition table
    sudo dd if=/dev/zero of="$SD_DEVICE" bs=512 count=34 status=progress

    # This would wipe the entire SD card, uncomment with caution, it can take a long time
    # sudo dd if=/dev/zero of=/dev/mmcblk0 status=progress
    if [[ $? -ne 0 ]]; then
      echo "dd failed!"
      exit 1
    fi

    echo "Target device is $SD_DEVICE"
  fi
fi

# echo "WARNING: All data on $SD_DEVICE will be erased!"
# read -p "Type 'YES' to continue: " CONFIRM
# if [[ "$CONFIRM" != "YES" ]]; then
#   echo "Aborted."
#   exit 1
# fi

# read -t 5 -p "I am going to wait for 5 seconds before deleting target device contents ..."

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

# Clean up stale mount points from interrupted runs so rm does not fail.
if [[ -d "$OUTDIR" ]]; then
  while IFS= read -r mount_point; do
    umount -lf "$mount_point" >/dev/null 2>&1 || sudo umount -lf "$mount_point" >/dev/null 2>&1 || true
  done < <(mount | awk '{print $3}' | grep "^$OUTDIR" | sort -r || true)
fi

rm -Rf "$OUTDIR" 2>/dev/null || sudo rm -Rf "$OUTDIR"
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

if [[ $BUILD_ONLY -eq 0 ]]; then
  sudo rpi-imager --cli --disable-verify "$OUTDIR/image-deb13-arm64-splash/deb13-arm64-splash.img" "$SD_DEVICE"
  echo "SD card setup complete."
else
  echo "Build-only mode complete. Image artifacts are in $OUTDIR"
fi