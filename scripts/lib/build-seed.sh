#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
USER_DATA="${REPO_ROOT}/images/cloud-init/user-data"
META_DATA="${REPO_ROOT}/images/cloud-init/meta-data"
BUILD_DIR="${REPO_ROOT}/build"
SEED_ISO="${BUILD_DIR}/seed.iso"
PLACEHOLDER="REPLACE_WITH_SSH_PUBLIC_KEY"

# Allow callers to redirect the seed ISO output without changing this script.
# BOTWORK_SEED_ISO (full path) takes precedence over BOTWORK_SEED_BUILD_DIR (directory only).
if [[ -n "${BOTWORK_SEED_ISO:-}" ]]; then
  SEED_ISO="${BOTWORK_SEED_ISO}"
elif [[ -n "${BOTWORK_SEED_BUILD_DIR:-}" ]]; then
  SEED_ISO="${BOTWORK_SEED_BUILD_DIR}/seed.iso"
fi

mkdir -p "$(dirname "${SEED_ISO}")"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

TMP_USER_DATA="${TMP_DIR}/user-data"
TMP_META_DATA="${TMP_DIR}/meta-data"
cp "${META_DATA}" "${TMP_META_DATA}"

if grep -q "${PLACEHOLDER}" "${USER_DATA}"; then
  if [[ -z "${BOTWORK_SSH_PUBLIC_KEY:-}" ]]; then
    echo "ERROR: ${USER_DATA} still contains ${PLACEHOLDER}." >&2
    echo "Set BOTWORK_SSH_PUBLIC_KEY to inject a key when building seed.iso." >&2
    exit 1
  fi

  sed "s|${PLACEHOLDER}|${BOTWORK_SSH_PUBLIC_KEY}|g" "${USER_DATA}" > "${TMP_USER_DATA}"
else
  cp "${USER_DATA}" "${TMP_USER_DATA}"
fi

if command -v cloud-localds >/dev/null 2>&1; then
  cloud-localds "${SEED_ISO}" "${TMP_USER_DATA}" "${TMP_META_DATA}"
elif command -v genisoimage >/dev/null 2>&1; then
  (
    cd "${TMP_DIR}"
    genisoimage -output "${SEED_ISO}" -volid cidata -joliet -rock user-data meta-data >/dev/null 2>&1
  )
elif command -v xorriso >/dev/null 2>&1; then
  (
    cd "${TMP_DIR}"
    xorriso -as mkisofs -output "${SEED_ISO}" -volid cidata -joliet -rock user-data meta-data >/dev/null 2>&1
  )
else
  echo "ERROR: install cloud-image-utils (cloud-localds) or genisoimage/xorriso." >&2
  exit 1
fi

echo "Created ${SEED_ISO}"
