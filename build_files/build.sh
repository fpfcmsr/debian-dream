#!/bin/bash

set -ouex pipefail

# enable repos for zfs
sed -i 's/ main$/ main contrib/' /etc/apt/sources.list || true
sed -i 's/ main$/ main contrib/' /etc/apt/sources.list.d/debian.sources || true || true
apt update

### Install packages

# zfs stuff
apt install -y linux-image-amd64 linux-headers-amd64
apt install -y zfs-dkms zfs-zed zfs-initramfs zfsutils-linux 

# systemdboot + luks stuff 
apt install -y cryptsetup cryptsetup-initramfs
apt install -y efitools sbsigntool efibootmgr openssl systemd-ukify rsync systemd-boot

#podman stuff
apt install -y podman

# ssh
apt install -y openssh-server

#cockpit stuff
apt install -y cockpit cockpit-bridge cockpit-machines cockpit-networkmanager cockpit-packagekit cockpit-podman cockpit-storaged cockpit-system cockpit-ws
# note to add the zfs manager stuff also 
mkdir /tmp/cockpit-zfs-manager
git clone https://github.com/45drives/cockpit-zfs-manager.git /tmp/cockpit-zfs-manager
sudo cp -r /tmp/cockpit-zfs-manager/zfs /usr/share/cockpit
