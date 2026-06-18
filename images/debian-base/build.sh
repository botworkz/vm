#!/usr/bin/env bash
# images/debian-base/build.sh — produce debian-base.qcow2 with libguestfs.
#
# Usage: build.sh <source-qcow2> <output-qcow2>
#
# Invoked by scripts/pack.sh inside the botforge container's image-build
# compose service. Receives an absolute path to the upstream Debian cloud
# image (downloaded by pack.sh) and an absolute path for the output qcow2.
#
# No SSH, no cloud-init at build time: virt-customize chroots into the disk
# via libguestfs and runs the provisioner scripts directly. The provisioner
# scripts are shared with downstream image templates under images/_shared/
# and have no idea whether they are running under packer or virt-customize.

set -euxo pipefail

SRC="${1:?source qcow2 path required}"
OUT="${2:?output qcow2 path required}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="${HERE}/../_shared"

DISK_SIZE="${DISK_SIZE:-10G}"
MEMSIZE="${MEMSIZE:-4096}"
SMP="${SMP:-4}"

mkdir -p "$(dirname "${OUT}")"
cp --reflink=auto "${SRC}" "${OUT}.partial"
qemu-img resize "${OUT}.partial" "${DISK_SIZE}"

virt-customize -a "${OUT}.partial" \
  --memsize "${MEMSIZE}" \
  --smp "${SMP}" \
  --run "${SHARED}/provisioners/00-base.sh" \
  --run "${SHARED}/provisioners/10-bot-user.sh" \
  --run "${SHARED}/provisioners/99-cleanup.sh" \
  --truncate /etc/machine-id \
  --delete /var/lib/dbus/machine-id

mv "${OUT}.partial" "${OUT}"
