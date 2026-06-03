#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=scripts/lib/tools.sh
source "${SCRIPT_DIR}/tools.sh"

usage() {
  cat <<USAGE
Usage: $0 --base-image <path> --overlay-image <path> --seed-iso <path> [--payload-iso <path>] [--accelerator kvm|tcg|auto] [--memory <MiB>] [--cpus <n>]
  botforge-backed run-vm is KVM-only and does not currently expose custom memory/cpu settings.
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

case "$(pick_accelerator "${ACCELERATOR}")" in
  kvm)
    ;;
  tcg)
    die "botforge-backed run-vm.sh is KVM-only; --accelerator tcg is no longer supported"
    ;;
esac

[[ "${MEMORY}" == "2048" ]] || die "botforge-backed run-vm.sh does not support --memory overrides"
[[ "${CPUS}" == "2" ]] || die "botforge-backed run-vm.sh does not support --cpus overrides"

EXTRA_MOUNTS=(
  --mount "$(dirname "$(realpath "${BASE_IMAGE}")")"
  --mount "$(dirname "$(realpath -m "${OVERLAY_IMAGE}")")"
  --mount "$(dirname "$(realpath "${SEED_ISO}")")"
)
if [[ -n "${PAYLOAD_ISO}" ]]; then
  EXTRA_MOUNTS+=(--mount "$(dirname "$(realpath "${PAYLOAD_ISO}")")")
fi

BOTFORGE_ARGS=(
  run
  --foreground
  --base-image "${BASE_IMAGE}"
  --overlay-image "${OVERLAY_IMAGE}"
  --seed-iso "${SEED_ISO}"
)
if [[ -n "${PAYLOAD_ISO}" ]]; then
  BOTFORGE_ARGS+=(--payload-iso "${PAYLOAD_ISO}")
fi

run_botforge_container --kvm "${EXTRA_MOUNTS[@]}" -- "${BOTFORGE_ARGS[@]}"
