#!/bin/bash

set -ouex pipefail

### Install packages

# general utilities 
apt install -y curl ca-certificates gnupg lsb-release jq vim git

# enable repos and install zfs
sed -i 's/ main$/ main contrib non-free non-free-firmware/' /etc/apt/sources.list || true
sed -i 's/ main$/ main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources || true || true
apt update
apt install -y linux-image-amd64 linux-headers-amd64
apt install -y zfs-dkms zfs-zed zfs-initramfs zfsutils-linux 

# systemdboot + luks stuff 
apt install -y cryptsetup cryptsetup-initramfs
apt install -y efitools sbsigntool efibootmgr openssl systemd-ukify rsync systemd-boot

#container stuff
apt install -y podman

# ssh
apt install -y openssh-server
# allow only ssh key login, and disable root ssh
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config

# virtualization
apt install -y qemu-kvm libvirt-daemon-system libvirt-clients virtinst bridge-utils

# firmware 
apt install -y firmware-linux 

#cockpit stuff
apt install -y cockpit cockpit-bridge cockpit-machines cockpit-networkmanager cockpit-packagekit cockpit-podman cockpit-storaged cockpit-system cockpit-ws
# note to add the zfs manager stuff also 
mkdir /tmp/cockpit-zfs-manager
git clone https://github.com/45drives/cockpit-zfs-manager.git /tmp/cockpit-zfs-manager
sudo cp -r /tmp/cockpit-zfs-manager/zfs /usr/share/cockpit
