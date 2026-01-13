#!/bin/bash
set -euo pipefail

IMAGE="$1"
SIZE="$2"

echo "Creating userdata image: $IMAGE ($SIZE)"

truncate -s "$SIZE" "$IMAGE"

if command -v mkfs.ext4 &> /dev/null; then
    mkfs.ext4 -F -L userdata "$IMAGE"
else
    docker run --rm --privileged \
        -v "$(dirname "$IMAGE"):/output" \
        alpine:3.19 \
        sh -c 'apk add --no-cache e2fsprogs && mkfs.ext4 -F -L userdata "/output/'"$(basename "$IMAGE")"'"'
fi

echo "Userdata image created"
