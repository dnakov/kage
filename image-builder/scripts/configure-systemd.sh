#!/bin/bash
set -euo pipefail

IMAGE="$1"

echo "Configuring vmd service (OpenRC)..."

docker run --rm --privileged \
    --platform linux/arm64 \
    -v "$IMAGE:/disk.img" \
    alpine:3.19 \
    sh -c '
set -euo pipefail

apk add --no-cache e2fsprogs

LOOP=$(losetup --find --show --partscan /disk.img)
mkdir -p /mnt/rootfs
mount "${LOOP}p2" /mnt/rootfs

# Create OpenRC init script for vmd
cat > /mnt/rootfs/etc/init.d/vmd << "INITSCRIPT"
#!/sbin/openrc-run

name="vmd"
description="VM Daemon - WebSocket bridge for process management"
command="/usr/local/bin/vmd"
command_background="yes"
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/vmd.log"
error_log="/var/log/vmd.log"

depend() {
    after localmount net
}
INITSCRIPT

chmod +x /mnt/rootfs/etc/init.d/vmd

# Enable vmd at boot
chroot /mnt/rootfs rc-update add vmd default

# Set environment
cat > /mnt/rootfs/etc/profile.d/sandbox.sh << "ENVSCRIPT"
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export IS_SANDBOX=yes
export VMD_PORT=8080
ENVSCRIPT

umount /mnt/rootfs
losetup -d "$LOOP"

echo "Service configured"
'

echo "vmd service configured successfully"
