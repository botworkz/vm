#!/usr/bin/env bash
# IMPORTANT: virt-customize's --run executes scripts via the guest's /bin/sh
# (dash on Debian) and silently ignores the shebang above. Keep this script
# POSIX/dash-clean. See 00-base.sh for the same note.
set -eux

apt-get clean || true
rm -rf /var/lib/apt/lists/*
rm -f /etc/dpkg/dpkg.cfg.d/02apt-speedup

truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

find /var/log -type f -exec truncate -s 0 {} \;
rm -rf /home/debian/.ssh /home/bot/.ssh /root/.ssh || true
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init clean --logs --seed || true
fi
rm -f /root/.bash_history /home/debian/.bash_history /home/bot/.bash_history || true

# fstrim is only meaningful when the filesystem is actually mounted on a
# block device. Inside the libguestfs appliance with --run, the rootfs is a
# qcow2-backed loop and fstrim works; under a host chroot or container it
# may error harmlessly. Either way: best-effort.
if command -v fstrim >/dev/null 2>&1; then
  fstrim -av || true
fi

sync
