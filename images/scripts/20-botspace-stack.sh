#!/usr/bin/env bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# ── Install Docker CE from Docker's official apt repository ──────────────────
# Debian's docker.io is consistently behind upstream and ships with awkward
# defaults (e.g. CLI split into docker-cli). Use the upstream Docker apt repo
# so the image gets a recent docker-ce + buildx + compose plugin.
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

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

systemctl enable docker.service
systemctl start docker.service

install -d -m 0755 /etc/botwork/envoy
rsync -a --delete /tmp/botspace-build-context/envoy/ /etc/botwork/envoy/
install -m 0644 /tmp/botspace-build-context/envoy/plugins-base.yaml /etc/botwork/plugins.yaml

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

# ── Load prebuilt botwork images staged by scripts/build-deps.sh ───────────
for svc in session-broker packer-tools mcp-echo; do
  /usr/bin/docker load -i /tmp/botspace-build-context/images/${svc}.tar
done

# ── Install launcher (Rust binary) ─────────────────────────────────────────
install -m 0755 -o root -g root \
  /tmp/botspace-build-context/bin/botwork-launcher /usr/local/bin/botwork-launcher
if command -v file >/dev/null 2>&1; then
  file /usr/local/bin/botwork-launcher | grep -q 'ELF .* executable' \
    || { echo "botwork-launcher is not a host-executable ELF" >&2; exit 1; }
else
  [[ -x /usr/local/bin/botwork-launcher ]] \
    || { echo "botwork-launcher binary missing or not executable" >&2; exit 1; }
fi

# ── Install botwork-tools (Rust binary) ──────────────────────────────────────
install -m 0755 -o root -g root \
  /tmp/botspace-build-context/bin/botwork-tools /usr/local/bin/botwork-tools
if command -v file >/dev/null 2>&1; then
  file /usr/local/bin/botwork-tools | grep -q 'ELF .* executable' \
    || { echo "botwork-tools is not a host-executable ELF" >&2; exit 1; }
else
  [[ -x /usr/local/bin/botwork-tools ]] \
    || { echo "botwork-tools binary missing or not executable" >&2; exit 1; }
fi

install -m 0644 /tmp/botspace-build-context/systemd/*.service /etc/systemd/system/
install -m 0644 /tmp/botspace-build-context/systemd/*.socket /etc/systemd/system/
systemctl daemon-reload
systemctl enable \
  botspace-network.service \
  botwork-launcher.socket \
  botwork-launcher.service \
  botspace-session-broker.service \
  botspace-envoy.service

rm -rf /tmp/botspace-build-context
