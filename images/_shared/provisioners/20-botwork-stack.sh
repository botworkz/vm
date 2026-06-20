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

install -d -m 0755 /etc/botwork/envoy
rsync -a --delete /tmp/botwork-build-context/envoy/ /etc/botwork/envoy/
install -m 0644 /tmp/botwork-build-context/envoy/plugins-base.yaml /etc/botwork/plugins.yaml

# Create the broker system group/user so the host dirs the broker
# containers write to are owned by a stable, named identity.
getent group  broker >/dev/null 2>&1 || groupadd --system --gid 1100 broker
getent passwd broker >/dev/null 2>&1 || useradd  --system --uid 1100 --gid 1100 \
                                                 --home-dir /nonexistent --no-create-home \
                                                 --shell /usr/sbin/nologin broker

# Top-level state dir. Owned by broker so the session-broker container can
# write /var/lib/botwork/sessions.json (and its .tmp) when launched with
# --user 1100:1100 by systemd.
install -d -m 0750 -o broker -g broker /var/lib/botwork

# Tenants dir is managed by the launcher (root) and contains per-tenant
# staging/agent dirs that the launcher chowns to BOTWORK_PLUGIN_UID/GID
# (1000:1000). Keep it root-owned so only the launcher writes into it.
install -d -m 0700 /var/lib/botwork/tenants

# ── DB state dir (sibling of /var/lib/botwork, distinct trust boundary) ─────
# Per RFE 97: postgres state lives on its own data disk, mounted at
# /var/lib/botwork-db on production deployments. The mountpoint is
# sibling-to (NOT inside) /var/lib/botwork so the trust boundary is
# visible at the path: nothing under /var/lib/botwork (which is the
# brokers' state surface; tenants/staging/etc.) can ever reach DB
# storage on disk.
#
# Two subdirs:
#   data/   — PGDATA, bind-mounted into the postgres container as
#             /var/lib/postgresql/data. Owned by uid:gid 999:999
#             which is the official postgres image's internal user.
#             The image's entrypoint will chown again on first run
#             if it needs to, so this is just a sensible default.
#   secret.env — created by botwork-db-init.service at first boot
#             (NOT here); contains POSTGRES_PASSWORD + BOTWORK_DATABASE_URL
#             rendered from the same random seed. Mode 0600, owned by root
#             (consumers read it via systemd EnvironmentFile= which runs
#             as root before dropping privileges to the broker uid).
#
# We do NOT create /var/lib/botwork-db itself with `install -d` here:
# on the production VM topology this path is the mount point for the
# DB data disk (LABEL=botspace-db, via space's cloud-init). If we
# pre-create + chown it here AND the mount lands on top, the perms we
# set are masked by the mount's root. For the image-build smoke test
# (no separate disk attached) the postgres container's bind-mount
# source must still exist, so we create the `data/` subdir lazily —
# the postgres systemd unit's ExecStartPre handles it.
install -d -m 0750 /var/lib/botwork-db

# ── Stage prebuilt botwork image tarballs for first-boot load ───────────────
# Under Packer we could `docker load` here because the build ran inside a
# booted VM with a live docker daemon. virt-customize runs in an offline
# libguestfs appliance — no systemd, no daemon, no /var/run/docker.sock.
# So instead we just bake the tarballs into the image at a well-known path,
# and a first-boot oneshot (botwork-image-loader.service) does the
# `docker load` + retag once docker.service is up. The loader is ordered
# Before=botwork-network.service so every downstream unit that references
# botwork/<svc>:local sees the tag.
install -d -m 0755 /usr/share/botwork/images
for svc in session-broker config-broker control-plane db-migrate postgres mcp-echo; do
  src="/tmp/botwork-build-context/images/${svc}.tar"
  [ -f "${src}" ] || { echo "missing image tar: ${src}" >&2; exit 1; }
  install -m 0644 -o root -g root "${src}" "/usr/share/botwork/images/${svc}.tar"
done

# Install the loader itself (the bash script lives under the same shared
# provisioners dir so it stays version-locked with this stack provisioner).
install -m 0755 -o root -g root \
  /tmp/botwork-build-context/firstboot/botwork-image-loader \
  /usr/local/sbin/botwork-image-loader

# Install the egress iptables installer. Same shape: bash script,
# baked into /usr/local/sbin, driven by a oneshot systemd unit that
# re-runs every boot. The unit (botwork-egress-iptables.service) is
# enabled below alongside the rest.
install -m 0755 -o root -g root \
  /tmp/botwork-build-context/firstboot/botwork-egress-iptables \
  /usr/local/sbin/botwork-egress-iptables

# Install the db-init script (paired with botwork-db-init.service).
# Same shape as the other two firstboot scripts: bash, /usr/local/sbin,
# driven by a oneshot unit. Materialises /var/lib/botwork-db/secret.env
# at first boot if missing; idempotent across reboots. See the script
# header for rotation semantics.
install -m 0755 -o root -g root \
  /tmp/botwork-build-context/firstboot/botwork-db-init \
  /usr/local/sbin/botwork-db-init

# ── Install launcher (Rust binary) ─────────────────────────────────────────
install -m 0755 -o root -g root \
  /tmp/botwork-build-context/bin/botwork-launcher /usr/local/bin/botwork-launcher
if command -v file >/dev/null 2>&1; then
  file /usr/local/bin/botwork-launcher | grep -q 'ELF .* executable' \
    || { echo "botwork-launcher is not a host-executable ELF" >&2; exit 1; }
else
  [ -x /usr/local/bin/botwork-launcher ] \
    || { echo "botwork-launcher binary missing or not executable" >&2; exit 1; }
fi

# ── Install botwork-tools (Rust binary) ──────────────────────────────────────
install -m 0755 -o root -g root \
  /tmp/botwork-build-context/bin/botwork-tools /usr/local/bin/botwork-tools
if command -v file >/dev/null 2>&1; then
  file /usr/local/bin/botwork-tools | grep -q 'ELF .* executable' \
    || { echo "botwork-tools is not a host-executable ELF" >&2; exit 1; }
else
  [ -x /usr/local/bin/botwork-tools ] \
    || { echo "botwork-tools binary missing or not executable" >&2; exit 1; }
fi

install -m 0644 /tmp/botwork-build-context/systemd/*.service /etc/systemd/system/
install -m 0644 /tmp/botwork-build-context/systemd/*.socket /etc/systemd/system/
# daemon-reload is a no-op in the libguestfs appliance ("Running in chroot,
# ignoring request"), but `systemctl enable` only does file-tree edits and
# works fine. The first real daemon-reload happens at boot.
systemctl daemon-reload || true
systemctl enable \
  botwork-image-loader.service \
  botwork-network.service \
  botwork-db-init.service \
  botwork-postgres.service \
  botwork-db-migrate.service \
  botwork-launcher.socket \
  botwork-launcher.service \
  botwork-config-broker.service \
  botwork-control-plane.service \
  botwork-session-broker.service \
  botwork-envoy.service \
  botwork-egress-envoy.service \
  botwork-egress-iptables.service

rm -rf /tmp/botwork-build-context
