#!/usr/bin/env bash
# Provisioners are executed by `botforge build` via `sudo bash /tmp/<script>.sh`
# in a booted guest. Keep this script POSIX/dash-clean anyway (no [[ ]], no
# `local`, no `set -o pipefail`) so CI shellcheck `-s sh` remains strict.
set -eux

export DEBIAN_FRONTEND=noninteractive

# Detect whether we are running under a live system (cloud-init, journald,
# friends) or a minimal/non-systemd context (e.g. chroot). In the latter,
# systemctl start/stop and cloud-init status --wait are either no-ops or
# pathological.
in_live_system() {
  [ -d /run/systemd/system ]
}

# Wait for cloud-init only when it actually has a chance of running.
if in_live_system && command -v cloud-init >/dev/null 2>&1; then
  cloud-init status --wait || true
fi

wait_for_apt_lock() {
  i=1
  while [ "$i" -le 120 ]; do
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
      && ! fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
      && ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
      return 0
    fi
    echo "Waiting for apt/dpkg locks to be released ($i/120)..."
    sleep 5
    i=$((i + 1))
  done
  echo "Timed out waiting for apt/dpkg locks" >&2
  return 1
}

# Temporarily quiesce unattended-upgrades during the build window: the
# Debian cloud image ships with apt-daily timers enabled and any timer
# firing during image build can race our own apt usage. We re-enable
# unattended-upgrades + apt-daily timers near the end of this script.
# In offline builds `systemctl stop` cannot reach a non-existent daemon
# but `systemctl disable`/`mask` are pure file-tree edits and work fine.
if in_live_system; then
  systemctl stop unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
fi
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
  git \
  curl \
  ca-certificates \
  gnupg \
  python3 \
  python3-yaml \
  jq \
  openssh-server \
  btop \
  emacs-nox

wait_for_apt_lock
eatmydata apt-get install -y --no-install-recommends unattended-upgrades

cat >/etc/apt/apt.conf.d/52botwork-unattended-upgrades <<'EOF'
// Run unattended-upgrades on the apt-daily-upgrade.timer.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";

// Security-only origins. The Debian-shipped 50unattended-upgrades file
// lists ${distro_id}:${distro_codename}-security as the default; this
// file deliberately RE-DECLARES the Origins-Pattern as security-only
// so we win against any future change to the shipped defaults (the
// 52-prefix sorts after 50 so the last-write-wins semantics of
// apt.conf.d picks our value).
Unattended-Upgrade::Origins-Pattern {
  "origin=Debian,codename=${distro_codename},label=Debian-Security";
  "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};

// Never reboot from inside the guest. The VM is part of botspace's
// managed redeploy flow; an in-guest reboot would race the host-side
// deploy lock and is the wrong thing in this topology.
Unattended-Upgrade::Automatic-Reboot "false";
EOF
chown root:root /etc/apt/apt.conf.d/52botwork-unattended-upgrades
chmod 0644 /etc/apt/apt.conf.d/52botwork-unattended-upgrades

systemctl unmask unattended-upgrades.service apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
systemctl enable unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

systemctl enable ssh || true
systemctl enable qemu-guest-agent || true
