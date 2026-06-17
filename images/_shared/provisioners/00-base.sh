#!/usr/bin/env bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# Wait for cloud-init to finish (users, ssh config, etc.). With apt work
# disabled in user-data this should return almost immediately, but keep
# the guard so future user-data changes don't reintroduce a race.
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init status --wait || true
fi

wait_for_apt_lock() {
  local i
  for i in $(seq 1 120); do
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
      && ! fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
      && ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
      return 0
    fi
    echo "Waiting for apt/dpkg locks to be released ($i/120)..."
    sleep 5
  done
  echo "Timed out waiting for apt/dpkg locks" >&2
  return 1
}

# Kill unattended-upgrades up front: the Debian cloud image ships with
# it enabled and any timer firing during the build would re-race us.
systemctl stop unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
systemctl disable unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl mask unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

wait_for_apt_lock
apt-get update

wait_for_apt_lock
apt-get install -y --no-install-recommends eatmydata

echo "force-unsafe-io" >/etc/dpkg/dpkg.cfg.d/02apt-speedup

wait_for_apt_lock
eatmydata apt-get install -y --no-install-recommends \
  qemu-guest-agent \
  sudo \
  vim-tiny \
  git \
  curl \
  ca-certificates \
  gnupg \
  python3 \
  python3-venv \
  python3-yaml \
  jq \
  openssh-server

wait_for_apt_lock
apt-get -y purge unattended-upgrades || true
apt-get -y autoremove --purge

systemctl enable ssh || true
systemctl enable qemu-guest-agent || true
