#!/bin/bash
set -euo pipefail

IMAGE="$1"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACTS_DIR="$(dirname "$IMAGE")"

echo "Installing Ubuntu ARM64..."

docker run --rm \
    --platform linux/arm64 \
    -v "$ARTIFACTS_DIR:/output" \
    ubuntu:22.04 \
    bash -c '
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y debootstrap e2fsprogs dosfstools grub-efi-arm64-bin mtools fdisk

# Stage 1: Create Ubuntu rootfs with debootstrap
echo "Running debootstrap..."
mkdir -p /staging/rootfs /staging/efi
debootstrap --arch=arm64 --variant=minbase --include=systemd,systemd-sysv,linux-image-generic,grub-efi-arm64,bubblewrap,ca-certificates,iproute2,iputils-ping,initramfs-tools,nftables jammy /staging/rootfs http://ports.ubuntu.com/ubuntu-ports

# Setup fstab
cat > /staging/rootfs/etc/fstab << EOF
/dev/vda2  /         ext4  defaults  0  1
/dev/vda1  /boot/efi vfat  defaults  0  2
EOF

# Set root password
echo "root:root" | chroot /staging/rootfs chpasswd

# Setup networking - use systemd-networkd with static IP for QEMU user-mode
mkdir -p /staging/rootfs/etc/systemd/network
cat > /staging/rootfs/etc/systemd/network/10-eth.network << NETCONF
[Match]
Name=en*

[Network]
Address=10.0.2.15/24
Gateway=10.0.2.2
DNS=10.0.2.3
NETCONF

# Enable systemd-networkd
chroot /staging/rootfs systemctl enable systemd-networkd

# Setup nftables firewall
cat > /staging/rootfs/etc/nftables.conf << 'NFTCONF'
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy accept;
        # Accept established connections
        ct state established,related accept
        # Accept localhost
        iif lo accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    chain output {
        type filter hook output priority 0; policy accept;
        # Allow localhost
        oif lo accept
        # Allow established connections
        ct state established,related accept
        # Allow DNS
        udp dport 53 accept
        tcp dport 53 accept
        # Allow HTTP/HTTPS
        tcp dport { 80, 443 } accept
        # Allow SSH (for git)
        tcp dport 22 accept
    }
}
NFTCONF

chroot /staging/rootfs systemctl enable nftables

echo "sandbox" > /staging/rootfs/etc/hostname

mkdir -p /staging/rootfs/home
mkdir -p /staging/rootfs/mnt
mkdir -p /staging/rootfs/usr/local/bin
mkdir -p /staging/rootfs/boot/efi

# Copy daemon binaries
cp /output/bin/vmd /staging/rootfs/usr/local/bin/
cp /output/bin/sandbox-helper /staging/rootfs/usr/local/bin/
chmod 755 /staging/rootfs/usr/local/bin/vmd
chmod 755 /staging/rootfs/usr/local/bin/sandbox-helper

# Create systemd service for vmd
cat > /staging/rootfs/etc/systemd/system/vmd.service << SVCFILE
[Unit]
Description=VM Daemon - WebSocket bridge for process management
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/vmd
Restart=always
RestartSec=3
User=root
Group=root
Environment=HOME=/root
Environment=VMD_PORT=8080
StandardOutput=journal
StandardError=journal
SyslogIdentifier=vmd

[Install]
WantedBy=multi-user.target
SVCFILE

# Enable vmd at boot
chroot /staging/rootfs systemctl enable vmd

# Add virtio modules to initramfs config
mkdir -p /staging/rootfs/etc/initramfs-tools
echo "virtio" >> /staging/rootfs/etc/initramfs-tools/modules
echo "virtio_pci" >> /staging/rootfs/etc/initramfs-tools/modules
echo "virtio_blk" >> /staging/rootfs/etc/initramfs-tools/modules
echo "virtio_net" >> /staging/rootfs/etc/initramfs-tools/modules
echo "virtio_console" >> /staging/rootfs/etc/initramfs-tools/modules
echo "virtio_ring" >> /staging/rootfs/etc/initramfs-tools/modules

# Regenerate initramfs
chroot /staging/rootfs update-initramfs -u -k all

# Set environment
cat > /staging/rootfs/etc/profile.d/sandbox.sh << ENVSCRIPT
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export IS_SANDBOX=yes
ENVSCRIPT

# Enable serial console
chroot /staging/rootfs systemctl enable serial-getty@hvc0.service

# Stage 2: Setup EFI partition contents
echo "Setting up EFI boot..."
mkdir -p /staging/efi/EFI/BOOT

grub-mkimage -o /staging/efi/EFI/BOOT/BOOTAA64.EFI -O arm64-efi -p /EFI/BOOT \
    part_gpt part_msdos fat ext2 normal boot linux configfile loopback chain efifwsetup \
    efi_gop ls search search_label search_fs_uuid search_fs_file test all_video gzio

# Create grub.cfg in EFI partition (GRUB looks here first)
cat > /staging/efi/EFI/BOOT/grub.cfg << GRUBCFG
set timeout=1
set default=0

# Search for root partition by label
search --no-floppy --label rootfs --set=root

menuentry "Ubuntu" {
    linux /boot/vmlinuz root=/dev/vda2 console=hvc0
    initrd /boot/initrd.img
}
GRUBCFG

# Also create grub.cfg in rootfs for reference
mkdir -p /staging/rootfs/boot/grub
cp /staging/efi/EFI/BOOT/grub.cfg /staging/rootfs/boot/grub/grub.cfg

# Stage 3: Create filesystem images
echo "Creating root filesystem image..."
mke2fs -t ext4 -d /staging/rootfs -L rootfs /tmp/root.img 4G

echo "Creating EFI filesystem image..."
dd if=/dev/zero of=/tmp/efi.img bs=1M count=64
mkfs.vfat -F32 /tmp/efi.img
mcopy -i /tmp/efi.img -s /staging/efi/EFI ::

# Stage 4: Create disk image with partition table
echo "Creating disk image with GPT..."

# Calculate sizes in sectors (512 bytes each)
EFI_SIZE=$(stat -c%s /tmp/efi.img)
ROOT_SIZE=$(stat -c%s /tmp/root.img)
EFI_SECTORS=$((EFI_SIZE / 512))
ROOT_SECTORS=$((ROOT_SIZE / 512))

# Layout: 1MB GPT header, then EFI, then root
EFI_START=2048
ROOT_START=$((EFI_START + EFI_SECTORS))
TOTAL_SECTORS=$((ROOT_START + ROOT_SECTORS + 34))  # +34 for backup GPT

truncate -s $((TOTAL_SECTORS * 512)) /output/rootfs.img

sfdisk /output/rootfs.img << PARTITION
label: gpt
unit: sectors

/output/rootfs.img1 : start=$EFI_START, size=$EFI_SECTORS, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
/output/rootfs.img2 : start=$ROOT_START, size=$ROOT_SECTORS, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
PARTITION

echo "Writing partition contents..."
dd if=/tmp/efi.img of=/output/rootfs.img bs=512 seek=$EFI_START conv=notrunc
dd if=/tmp/root.img of=/output/rootfs.img bs=512 seek=$ROOT_START conv=notrunc

echo "Ubuntu installation complete"
'

echo "Base system installed successfully"
