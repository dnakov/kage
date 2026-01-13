#!/bin/bash
set -euo pipefail

IMAGE="$1"
BIN_DIR="$2"

echo "Installing vmd and sandbox-helper..."

docker run --rm \
    --platform linux/arm64 \
    -v "$(dirname "$IMAGE"):/output" \
    -v "$BIN_DIR:/binaries:ro" \
    ubuntu:22.04 \
    bash -c '
set -euo pipefail

apt-get update
apt-get install -y e2fsprogs fdisk

# Get root partition (partition 2) start sector from GPT
ROOT_START=$(sfdisk -d /output/rootfs.img | grep "rootfs.img2" | sed "s/.*start= *\([0-9]*\).*/\1/")
ROOT_SIZE=$(sfdisk -d /output/rootfs.img | grep "rootfs.img2" | sed "s/.*size= *\([0-9]*\).*/\1/")

echo "Root partition: start=$ROOT_START sectors, size=$ROOT_SIZE sectors"

# Extract root partition
dd if=/output/rootfs.img of=/tmp/root.img bs=512 skip=$ROOT_START count=$ROOT_SIZE

# Use debugfs to write files into the ext4 image (remove first to overwrite)
debugfs -w /tmp/root.img -R "rm /usr/local/bin/vmd" 2>/dev/null || true
debugfs -w /tmp/root.img -R "rm /usr/local/bin/sandbox-helper" 2>/dev/null || true
echo "write /binaries/vmd /usr/local/bin/vmd" | debugfs -w /tmp/root.img
echo "write /binaries/sandbox-helper /usr/local/bin/sandbox-helper" | debugfs -w /tmp/root.img

# Write the modified partition back
dd if=/tmp/root.img of=/output/rootfs.img bs=512 seek=$ROOT_START conv=notrunc

echo "Daemons installed"
'

echo "Daemons installed successfully"
