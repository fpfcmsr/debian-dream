#!/bin/bash

set -ouex pipefail

# enable repos for zfs
sed -i 's/ main$/ main contrib/' /etc/apt/sources.list || true
sed -i 's/ main$/ main contrib/' /etc/apt/sources.list.d/debian.sources || true || true
apt update

### Install packages

# zfs stuff
apt install -y linux-image-amd64 linux-headers-amd64
apt install -y zfs-initramfs zfsutils-linux zfs-dkms cryptsetup cryptsetup-initramfs

# systemdboot stuff
apt install -y efitools sbsigntool efibootmgr openssl sbverify systemd-ukify rsync
apt install -y systemd-boot 

#podman stuff
apt install -y podman 

#cockpit stuff
# apt install -y cockpit cockpit-machines

