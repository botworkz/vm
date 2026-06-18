#!/usr/bin/env bash
# images/botwork/build.sh — produce debian-13-botwork.qcow2 with libguestfs.
#
# Usage: build.sh <source-qcow2> <output-qcow2>
#
# Invoked by scripts/pack.sh inside the botforge container's image-build
# compose service, with --source pointing at the previously built
# debian-base.qcow2 from images/debian-base.
#
# Stages the payload context exactly as 20-botwork-stack.sh expects at
# /tmp/botwork-build-context/{envoy,systemd,bin,images} by tarring on the
# host, uploading the archive into the guest, and untarring there — that
# round-trip avoids virt-customize --copy-in's "preserve source basename"
# quirk and keeps the script's existing expectations unchanged.

set -euxo pipefail

SRC="${1:?source qcow2 path required}"
OUT="${2:?output qcow2 path required}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHARED="${HERE}/../_shared"

DISK_SIZE="${DISK_SIZE:-10G}"
MEMSIZE="${MEMSIZE:-4096}"
SMP="${SMP:-4}"
BUILD_DIR="${BUILD_DIR:?BUILD_DIR (host build/ dir) required}"

[[ -d "${BUILD_DIR}/bin" ]] \
  || { echo "missing ${BUILD_DIR}/bin (run scripts/build-deps.sh first)" >&2; exit 1; }
[[ -d "${BUILD_DIR}/images/baked" ]] \
  || { echo "missing ${BUILD_DIR}/images/baked (run scripts/build-deps.sh first)" >&2; exit 1; }

CTX="$(mktemp -d)"
trap 'rm -rf "${CTX}" "${OUT}.partial" "${BUILD_DIR}/botwork-ctx.tar"' EXIT

# Mirror the layout 20-botwork-stack.sh consumes at
# /tmp/botwork-build-context/{envoy,systemd,bin,images}.
cp -a "${HERE}/payload/envoy"       "${CTX}/envoy"
cp -a "${HERE}/payload/systemd"     "${CTX}/systemd"
cp -a "${BUILD_DIR}/bin"            "${CTX}/bin"
mkdir -p "${CTX}/images"
cp -a "${BUILD_DIR}/images/baked/." "${CTX}/images/"

CTX_TAR="${BUILD_DIR}/botwork-ctx.tar"
tar -C "${CTX}" -cf "${CTX_TAR}" .

mkdir -p "$(dirname "${OUT}")"
cp --reflink=auto "${SRC}" "${OUT}.partial"
qemu-img resize "${OUT}.partial" "${DISK_SIZE}"

virt-customize -a "${OUT}.partial" \
  --memsize "${MEMSIZE}" \
  --smp "${SMP}" \
  --mkdir /tmp/botwork-build-context \
  --upload "${CTX_TAR}:/tmp/botwork-build-context/ctx.tar" \
  --run-command 'tar -C /tmp/botwork-build-context -xf /tmp/botwork-build-context/ctx.tar && rm /tmp/botwork-build-context/ctx.tar' \
  --run "${SHARED}/provisioners/20-botwork-stack.sh" \
  --run "${SHARED}/provisioners/99-cleanup.sh" \
  --truncate /etc/machine-id \
  --delete /var/lib/dbus/machine-id

mv "${OUT}.partial" "${OUT}"
