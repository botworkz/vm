#!/usr/bin/env bash
# IMPORTANT: virt-customize's --run executes scripts via the guest's /bin/sh
# (dash on Debian) and silently ignores the shebang above. Keep this script
# POSIX/dash-clean: no [[ ]], no `local`, no arrays. Use `command -v` /
# `[ ]` / explicit braces.
set -eux

export DEBIAN_FRONTEND=noninteractive

# ── Install Docker CE from Docker's official apt repository ──────────────────
# Debian's docker.io is consistently behind upstream and ships with awkward
# defaults (e.g. CLI split into docker-cli). Use the upstream Docker apt repo
# so the image gets a recent docker-ce + buildx + compose plugin.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Sourced at runtime in the guest; shellcheck can't see the file so silence
# SC1091. `VERSION_CODENAME` (used below) comes from this file.
# shellcheck source=/dev/null
. /etc/os-release
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
eatmydata apt-get install -y --no-install-recommends \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin \
  jq \
  rsync

usermod -aG docker bot

# docker.service is enabled here so the daemon comes up on first boot. We do
# NOT `systemctl start` it: virt-customize runs inside an offline libguestfs
# appliance with no systemd as pid 1, so `systemctl start docker.service`
# would error with "Running in chroot, ignoring command 'start'" and any
# subsequent `docker load` against /var/run/docker.sock would fail because
# the daemon never came up. Image loading is deferred to a first-boot oneshot
# (botwork-image-loader.service) instead.
systemctl enable docker.service
