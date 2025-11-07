#!/usr/bin/env bash
set -euo pipefail

# =======================
# CONFIG / ARGS
# =======================
DISK1="${1:?Usage: $0 <DISK1-by-id> <DISK2-by-id> <IMAGE> <HOSTNAME> [NEWUSER]}"
DISK2="${2:?Usage: $0 <DISK1-by-id> <DISK2-by-id> <IMAGE> <HOSTNAME> [NEWUSER]}"
IMAGE="${3:?Usage: $0 <DISK1> <DISK2> <IMAGE> <HOSTNAME> [NEWUSER]}"
HOSTNAME="${4:?Usage: $0 <DISK1> <DISK2> <IMAGE> <HOSTNAME> [NEWUSER]}"
NEWUSER="${5:-admin}"   # default admin username if not provided

# Pools + datasets
BPOOL="bpool"
RPOOL="rpool"
ROOT_DS="${RPOOL}/ROOT/debian"
BOOT_DS="${BPOOL}/BOOT/debian"

# Partition sizes
ESP_SIZE="512M"

# LUKS mapping names (used both now and at boot)
CRYPT_NAME1="crypt_rpool1"
CRYPT_NAME2="crypt_rpool2"

# Optional: preseed non-interactive secrets via env vars (use with care)
#   export LUKS_PASSPHRASE="..."
#   export NEWUSER_PASSWORD="..."
LUKS_PASSPHRASE="${LUKS_PASSPHRASE:-}"
NEWUSER_PASSWORD="${NEWUSER_PASSWORD:-}"

# ==============
# PRE-FLIGHT
# ==============
if [[ ! -d /sys/firmware/efi ]]; then
  echo "Error: This script targets UEFI systems. Boot the Live ISO in UEFI mode."
  exit 1
fi

apt-get update
apt-get install -y systemd dosfstools gdisk cryptsetup-bin zfsutils-linux podman efibootmgr

podman pull "${IMAGE}" || true

# ===========================
# 1) Partition with systemd-repart
# ===========================
REPART_DIR=/tmp/repart.d
rm -rf "${REPART_DIR}"; mkdir -p "${REPART_DIR}"

cat >"${REPART_DIR}/10-esp.conf"<<EOF
[Partition]
Type=esp
SizeMin=${ESP_SIZE}
SizeMax=${ESP_SIZE}
Label=ESP
Format=vfat
EOF

cat >"${REPART_DIR}/20-bpool.conf"<<'EOF'
[Partition]
# ZFS member GUID
Type=6A898CC3-1DD2-11B2-99A6-080020736631
SizeMin=1024M
SizeMax=1024M
Label=bpool
EOF

cat >"${REPART_DIR}/30-rpool-luks.conf"<<'EOF'
[Partition]
# Linux LUKS GUID
Type=CA7D7CCB-63ED-4C53-861C-1742536059CC
Label=rpool-crypt
EOF

for D in "${DISK1}" "${DISK2}"; do
  echo "Partitioning ${D}…"
  systemd-repart --definitions="${REPART_DIR}" --empty=force --dry-run=no "${D}"
done

sleep 2; partprobe || true; udevadm settle || true

ESP1="${DISK1}-part2"; ESP2="${DISK2}-part2"
BPOOL1="${DISK1}-part3"; BPOOL2="${DISK2}-part3"
RCRYPT1="${DISK1}-part4"; RCRYPT2="${DISK2}-part4"

# ===========================
# 2) ZFS boot pool (unencrypted)
# ===========================
zpool create -f \
  -o ashift=12 -o autotrim=on \
  -o compatibility=grub2 \
  -o cachefile=/etc/zfs/zpool.cache \
  -O devices=off \
  -O acltype=posixacl -O xattr=sa \
  -O compression=lz4 \
  -O normalization=formD \
  -O relatime=on \
  -O canmount=off -O mountpoint=/boot -R /mnt \
  "${BPOOL}" mirror "${BPOOL1}" "${BPOOL2}"

# ===========================
# 3) LUKS-on-ZFS root (prompt once, reuse for both)
# ===========================
if [[ -z "${LUKS_PASSPHRASE}" ]]; then
  echo
  while true; do
    read -r -s -p "Enter LUKS passphrase: " L1; echo
    read -r -s -p "Confirm LUKS passphrase: " L2; echo
    [[ "$L1" == "$L2" ]] && LUKS_PASSPHRASE="$L1" && unset L1 L2 && break
    echo "Passphrases did not match. Try again."
  done
fi

# Keep the secret in a tmpfile (RAM), not in argv/environment
PASSFILE="$(mktemp)"
chmod 600 "${PASSFILE}"
printf '%s' "${LUKS_PASSPHRASE}" > "${PASSFILE}"

cryptsetup luksFormat --type luks2 -d "${PASSFILE}" "${RCRYPT1}"
cryptsetup luksFormat --type luks2 -d "${PASSFILE}" "${RCRYPT2}"
cryptsetup open -d "${PASSFILE}" "${RCRYPT1}" "${CRYPT_NAME1}"
cryptsetup open -d "${PASSFILE}" "${RCRYPT2}" "${CRYPT_NAME2}"

# Wipe sensitive material ASAP
shred -u "${PASSFILE}"
unset LUKS_PASSPHRASE PASSFILE

# Root pool on the two opened LUKS devices
zpool create -f \
  -o ashift=12 -o autotrim=on \
  -O acltype=posixacl -O xattr=sa -O dnodesize=auto \
  -O compression=lz4 \
  -O normalization=formD \
  -O relatime=on \
  -O canmount=off -O mountpoint=/ -R /mnt \
  "${RPOOL}" mirror "/dev/mapper/${CRYPT_NAME1}" "/dev/mapper/${CRYPT_NAME2}"

# Datasets
zfs create -o canmount=off -o mountpoint=none "${RPOOL}/ROOT"
zfs create -o canmount=off -o mountpoint=none "${BPOOL}/BOOT"
zfs create -o canmount=noauto -o mountpoint=/ "${RPOOL}/ROOT/debian"
zfs mount "${ROOT_DS}"
zfs create -o mountpoint=/boot "${BOOT_DS}"
zfs create "${RPOOL}/home"
zfs create -o mountpoint=/root "${RPOOL}/home/root"; chmod 700 /mnt/root
zfs create -o canmount=off "${RPOOL}/var"
zfs create -o canmount=off "${RPOOL}/var/lib"
zfs create "${RPOOL}/var/log"
zfs create "${RPOOL}/var/spool"

mkdir -p /mnt/boot/efi
mount "${ESP1}" /mnt/boot/efi

# ===========================
# 4) Materialize the bootc image onto ZFS root
# ===========================
podman run --rm --privileged --pid=host --ipc=host --uts=host \
  --security-opt label=disable \
  -v /dev:/dev -v /run:/run -v /sys:/sys \
  -v /mnt:/sysroot \
  "${IMAGE}" \
  bootc install to-filesystem /sysroot \
    --karg="root=ZFS=${ROOT_DS}"

# ===========================
# 5) System config in target (crypttab, hostname, user, root lock)
# ===========================
UUID_RCRYPT1="$(blkid -s UUID -o value "${RCRYPT1}")"
UUID_RCRYPT2="$(blkid -s UUID -o value "${RCRYPT2}")"
cat > /mnt/etc/crypttab <<EOF
${CRYPT_NAME1} UUID=${UUID_RCRYPT1} none luks,discard
${CRYPT_NAME2} UUID=${UUID_RCRYPT2} none luks,discard
EOF

echo "${HOSTNAME}" > /mnt/etc/hostname

# Prepare admin user password if not provided via env
if [[ -z "${NEWUSER_PASSWORD}" ]]; then
  echo
  echo "Create password for user '${NEWUSER}':"
  while true; do
    read -r -s -p "Enter password: " P1; echo
    read -r -s -p "Confirm password: " P2; echo
    [[ "$P1" == "$P2" ]] && NEWUSER_PASSWORD="$P1" && unset P1 P2 && break
    echo "Passwords did not match. Try again."
  done
fi

# Enter the target and finalize
chroot /mnt /bin/bash -euxo pipefail <<'CHROOT_EOF'
# small helper to check existence of a command
have() { command -v "\$1" >/dev/null 2>&1; }

# Ensure zfs services are enabled when present
mkdir -p /etc/zfs/zfs-list.cache
: > /etc/zfs/zfs-list.cache/bpool || true
: > /etc/zfs/zfs-list.cache/rpool || true
systemctl enable zfs-mount.service zfs-import-cache.service zfs-import-scan.service || true

# GRUB baseline: ensure ZFS root arg is present
if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
  sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/debian"|' /etc/default/grub
else
  echo 'GRUB_CMDLINE_LINUX="root=ZFS=rpool/ROOT/debian"' >> /etc/default/grub
fi

# Make sure 'sudo' exists (your image should include it for immutable setups)
if ! have sudo; then
  echo "WARNING: 'sudo' not found in target image. Please include it in your bootc image."
fi

CHROOT_EOF

# Create the admin user, add to sudo, set password, lock root, harden SSH (do this outside-heredoc to pass secrets safely)
chroot /mnt /usr/sbin/useradd -m -s /bin/bash -G sudo "${NEWUSER}" || true
echo "${NEWUSER}:${NEWUSER_PASSWORD}" | chroot /mnt /usr/sbin/chpasswd
unset NEWUSER_PASSWORD

# Lock root and optionally disable interactive shell
chroot /mnt /usr/sbin/passwd -l root || true
chroot /mnt /usr/sbin/usermod -s /usr/sbin/nologin root || true

# Disable SSH root login if sshd is present
if [[ -f /mnt/etc/ssh/sshd_config ]]; then
  sed -ri 's/^#?PermitRootLogin .*/PermitRootLogin no/' /mnt/etc/ssh/sshd_config
fi

# Rebuild grub config inside target
chroot /mnt update-grub || true
grub-install --target=x86_64-efi --efi-directory=/mnt/boot/efi --bootloader-id=debian --recheck --no-floppy

# ===========================
# 6) Mirror GRUB to second ESP + bootfs
# ===========================
umount /mnt/boot/efi
dd if="${ESP1}" of="${ESP2}" bs=1M conv=fsync
efibootmgr -c -g -d "${DISK2}" -p 2 -L "debian-2" -l '\EFI\debian\grubx64.efi'
mount "${ESP1}" /mnt/boot/efi

zpool set bootfs="${ROOT_DS}" "${RPOOL}"

# ===========================
# 7) Clean up
# ===========================
sync
mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | xargs -r umount -lf || true
zpool export -a || true

echo
echo "Install complete. On boot you'll be asked to unlock both LUKS devices."
