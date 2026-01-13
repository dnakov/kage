#!/bin/bash
set -euo pipefail

IMAGE="$1"
SIZE="$2"

echo "Creating GPT disk image: $IMAGE ($SIZE)"

truncate -s "$SIZE" "$IMAGE"

# Use Docker to create GPT partitions (macOS fdisk doesn't support GPT)
docker run --rm \
    -v "$(dirname "$IMAGE"):/output" \
    alpine:3.19 \
    sh -c "
apk add --no-cache sgdisk
sgdisk --clear /output/$(basename "$IMAGE")
sgdisk --new=1:0:+64M --typecode=1:ef00 --change-name=1:EFI /output/$(basename "$IMAGE")
sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:rootfs /output/$(basename "$IMAGE")
sgdisk --print /output/$(basename "$IMAGE")
"

echo "GPT disk image created successfully"
