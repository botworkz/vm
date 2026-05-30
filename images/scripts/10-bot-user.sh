#!/usr/bin/env bash
set -euxo pipefail

id bot >/dev/null 2>&1 || {
  echo "ERROR: bot user not found; verify cloud-init user creation." >&2
  exit 1
}
install -d -m 0755 -o bot -g bot /home/bot/workdir
getent group docker >/dev/null 2>&1 || groupadd --system docker
usermod -aG docker bot

# TODO(phlax): add bot runtime setup here (dependencies, services, and cache mount wiring).
