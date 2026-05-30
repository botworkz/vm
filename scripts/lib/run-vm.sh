#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/common.sh"

usage() {
  cat <<USAGE
Usage: $0 --base-image <path> --overlay-image <path> --seed-iso <path> [--payload-iso <path>] [--accelerator kvm|tcg|auto] [--memory <MiB>] [--cpus <n>]
USAGE
}

BASE_IMAGE=""
OVERLAY_IMAGE=""
SEED_ISO=""
PAYLOAD_ISO=""
ACCELERATOR="auto"
MEMORY="2048"
CPUS="2"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-image)
      BASE_IMAGE="${2:-}"
      shift 2
      ;;
    --overlay-image)
      OVERLAY_IMAGE="${2:-}"
      shift 2
      ;;
    --seed-iso)
      SEED_ISO="${2:-}"
      shift 2
      ;;
    --payload-iso)
      PAYLOAD_ISO="${2:-}"
      shift 2
      ;;
    --accelerator)
      ACCELERATOR="${2:-}"
      shift 2
      ;;
    --memory)
      MEMORY="${2:-}"
      shift 2
      ;;
    --cpus)
      CPUS="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "${BASE_IMAGE}" ]] || die "--base-image is required"
[[ -n "${OVERLAY_IMAGE}" ]] || die "--overlay-image is required"
[[ -n "${SEED_ISO}" ]] || die "--seed-iso is required"

BASE_IMAGE="$(realpath "${BASE_IMAGE}")"
OVERLAY_IMAGE="$(realpath -m "${OVERLAY_IMAGE}")"
SEED_ISO="$(realpath "${SEED_ISO}")"
if [[ -n "${PAYLOAD_ISO}" ]]; then
  PAYLOAD_ISO="$(realpath "${PAYLOAD_ISO}")"
fi
[[ -f "${BASE_IMAGE}" ]] || die "base image not found at ${BASE_IMAGE}"
[[ -f "${SEED_ISO}" ]] || die "seed ISO not found at ${SEED_ISO}"
if [[ -n "${PAYLOAD_ISO}" ]]; then
  [[ -f "${PAYLOAD_ISO}" ]] || die "payload ISO not found at ${PAYLOAD_ISO}"
fi

mkdir -p "$(dirname "${OVERLAY_IMAGE}")"
rm -f "${OVERLAY_IMAGE}"
qemu-img create -f qcow2 -F qcow2 -b "${BASE_IMAGE}" "${OVERLAY_IMAGE}" >/dev/null

SELECTED_ACCEL="$(pick_accelerator "${ACCELERATOR}")"
ACCEL_ARGS=("-accel" "${SELECTED_ACCEL}")
DRIVE_ARGS=(
  -drive "if=virtio,format=qcow2,file=${OVERLAY_IMAGE}"
  -drive "if=virtio,format=raw,file=${SEED_ISO},readonly=on"
)
if [[ -n "${PAYLOAD_ISO}" ]]; then
  DRIVE_ARGS+=(-drive "if=virtio,format=raw,file=${PAYLOAD_ISO},readonly=on")
fi
if [[ "${SELECTED_ACCEL}" == "tcg" ]]; then
  log_warn "KVM unavailable; using slower TCG accelerator"
fi

exec qemu-system-x86_64 \
  "${ACCEL_ARGS[@]}" \
  -m "${MEMORY}" \
  -smp "${CPUS}" \
  -nographic \
  "${DRIVE_ARGS[@]}" \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0
