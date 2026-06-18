#!/usr/bin/env bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# virt-customize runs everything as root in the libguestfs appliance, so there
# is no cloud-init pre-creating the bot user any more. Create the system
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
install -d -m 0750 /etc/sudoers.d
install -m 0440 /dev/stdin /etc/sudoers.d/90-botwork <<'SUDOERS'
debian ALL=(ALL) NOPASSWD:ALL
bot    ALL=(ALL) NOPASSWD:ALL
SUDOERS

install -d -m 0755 -o bot -g bot /home/bot/workdir

getent group docker >/dev/null 2>&1 || groupadd --system docker
usermod -aG docker bot

# TODO(phlax): add bot runtime setup here (dependencies, services, and cache mount wiring).
