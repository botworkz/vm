#!/usr/bin/env bash
# IMPORTANT: virt-customize's --run executes scripts via the guest's /bin/sh
# (dash on Debian) and silently ignores the shebang above. Keep this script
# POSIX/dash-clean. See 00-base.sh for the same note.
set -eux

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
# NOTE: `install -m 0440 /dev/stdin <dest> <<HEREDOC` works in a live shell
# (GNU coreutils stats fd 0) but fails inside the libguestfs supermin
# appliance with "cannot stat '/dev/stdin': No such file or directory",
# because /proc/self/fd is not wired through the way the host kernel does.
# Write the file directly and chmod/chown after the fact.
install -d -m 0750 /etc/sudoers.d
cat >/etc/sudoers.d/90-botwork <<'SUDOERS'
debian ALL=(ALL) NOPASSWD:ALL
bot    ALL=(ALL) NOPASSWD:ALL
SUDOERS
chown root:root /etc/sudoers.d/90-botwork
chmod 0440      /etc/sudoers.d/90-botwork

install -d -m 0755 -o bot -g bot /home/bot/workdir
