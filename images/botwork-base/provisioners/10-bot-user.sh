#!/usr/bin/env bash
# Provisioners are executed by `botforge build` via `sudo bash /tmp/<script>.sh`
# in a booted guest. Keep this script POSIX/dash-clean too; see 00-base.sh.
set -eux

export DEBIAN_FRONTEND=noninteractive

# Build-time provisioning runs as root, so there is no cloud-init pre-creating
# the bot user. Create the system
# identities directly. Keep the explicit uid/gid so any files baked into
# /home/bot by later provisioners line up with the same numeric identity that
# downstream systemd units use.
#
# We also create the `debian` user the upstream Debian cloud image normally
# materializes via its baked-in cloud-init default-user config. Test-time
# cidata only configures `bot`, but `debian` is asserted by the goss specs and
# is the historical interactive account on Debian cloud images.
if ! getent passwd debian >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --groups sudo debian
  passwd -l debian   # locked password, key-only login (matches cloud-init posture)
fi
if ! getent passwd bot >/dev/null 2>&1; then
  getent group bot >/dev/null 2>&1 || groupadd --gid 2000 bot
  useradd --create-home --shell /bin/bash --uid 2000 --gid 2000 bot
fi

# Mirror what cloud-init's sudo: ["ALL=(ALL) NOPASSWD:ALL"] used to install.
# NOTE: write the file directly and chmod/chown after the fact rather than
# relying on `/dev/stdin` install patterns.
install -d -m 0750 /etc/sudoers.d
cat >/etc/sudoers.d/90-botwork <<'SUDOERS'
debian ALL=(ALL) NOPASSWD:ALL
bot    ALL=(ALL) NOPASSWD:ALL
SUDOERS
chown root:root /etc/sudoers.d/90-botwork
chmod 0440      /etc/sudoers.d/90-botwork

install -d -m 0755 -o bot -g bot /home/bot/workdir
