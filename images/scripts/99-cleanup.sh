#!/usr/bin/env bash
set -euxo pipefail

apt-get clean || true
rm -rf /var/lib/apt/lists/*
rm -f /etc/dpkg/dpkg.cfg.d/02apt-speedup

truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

find /var/log -type f -exec truncate -s 0 {} \;
rm -rf /home/debian/.ssh /home/bot/.ssh /root/.ssh || true
cloud-init clean --logs --seed || true
rm -f /root/.bash_history /home/debian/.bash_history /home/bot/.bash_history || true

if command -v fstrim >/dev/null 2>&1; then
  fstrim -av || true
fi

sync
