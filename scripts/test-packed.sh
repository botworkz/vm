#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<USAGE
Usage: $0 [--image <path>] [--key <path>] [--keep-running] [-h|--help]
USAGE
}

IMAGE_OVERRIDE=""
KEY_PATH="$(default_private_key_path)"
KEEP_RUNNING=false
VM_PID=""
OVERLAY_IMAGE="${BUILD_DIR}/overlay-smoke.qcow2"
VM_LOG="${BUILD_DIR}/vm-smoke.log"
SSH_HOST="${SSH_HOST:-127.0.0.1}"
SSH_PORT="${SSH_PORT:-2222}"
STABILIZATION_ATTEMPTS="${STABILIZATION_ATTEMPTS:-5}"
REQUIRED_STABLE_SSH_PROBES="${REQUIRED_STABLE_SSH_PROBES:-2}"
SSH_DESTINATION="bot@${SSH_HOST}"

retry_transport_cmd() {
  local label="$1"
  local max_attempts="$2"
  local sleep_seconds="$3"
  local attempt exit_code
  shift 3

  for attempt in $(seq 1 "${max_attempts}"); do
    if "$@"; then
      return 0
    else
      exit_code=$?
    fi
    if [[ "${exit_code}" -ne 255 ]]; then
      return "${exit_code}"
    fi

    if [[ "${attempt}" -eq "${max_attempts}" ]]; then
      log_error "${label} failed after ${max_attempts} attempts"
      return "${exit_code}"
    fi

    log_warn "${label} failed with exit code ${exit_code}; retrying (${attempt}/${max_attempts})"
    sleep "${sleep_seconds}"
  done
}

retry_ssh_cmd() {
  local label="$1"
  shift
  retry_transport_cmd "${label}" 5 3 "$@"
}

retry_scp() {
  local label="$1"
  shift
  retry_transport_cmd "${label}" 5 3 "$@"
}

dump_failure_diagnostics() {
  local exit_code="$1"

  log_error "Smoke test failed with exit code ${exit_code}; collecting diagnostics"

  if [[ -f "${KEY_PATH}" ]]; then
    retry_ssh_cmd "Collecting remote diagnostics" \
      ssh "${SSH_OPTS[@]}" -i "${KEY_PATH}" -p "${SSH_PORT}" "${SSH_DESTINATION}" \
      'sudo systemctl --failed --no-pager || true; \
       sudo journalctl -u ssh -u botwork-launcher \
                       -u botspace-envoy -u botspace-session-broker \
                       --no-pager -n 200 || true; \
       sudo cloud-init status --long || true' || true
  fi

  tail -n 200 "${VM_LOG}" || true
}

cleanup() {
  local exit_code=$?

  if [[ "${exit_code}" -ne 0 ]]; then
    dump_failure_diagnostics "${exit_code}"
  fi

  if [[ "${KEEP_RUNNING}" == "true" ]]; then
    log_warn "Keeping VM running for debugging (PID: ${VM_PID:-unknown})"
    return "${exit_code}"
  fi

  if [[ -n "${VM_PID}" ]] && kill -0 "${VM_PID}" >/dev/null 2>&1; then
    kill "${VM_PID}" >/dev/null 2>&1 || true
    wait "${VM_PID}" >/dev/null 2>&1 || true
  fi
  rm -f "${OVERLAY_IMAGE}"
  return "${exit_code}"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      IMAGE_OVERRIDE="${2:-}"
      shift 2
      ;;
    --key)
      KEY_PATH="${2:-}"
      shift 2
      ;;
    --keep-running)
      KEEP_RUNNING=true
      shift
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

mkdir -p "${BUILD_DIR}"
IMAGE_PATH="$(discover_image "${IMAGE_OVERRIDE}")"
KEY_PATH="$(realpath -m "${KEY_PATH}")"
[[ -f "${KEY_PATH}" ]] || die "private key not found: ${KEY_PATH}"

export BOTWORK_SSH_PUBLIC_KEY="${BOTWORK_SSH_PUBLIC_KEY:-$(public_key_from_private "${KEY_PATH}")}"

if should_use_compose_qemu; then
  ensure_command docker
  SELECTED_ACCEL="$(pick_accelerator auto)"
  SERVICE="$(compose_service_for_accel "${SELECTED_ACCEL}")"
  HOST_KVM_GID_VALUE="${HOST_KVM_GID:-$(getent group kvm 2>/dev/null | cut -d: -f3 || true)}"
  if [[ -z "${HOST_KVM_GID_VALUE}" ]]; then
    HOST_KVM_GID_VALUE="993"
  fi
  COMPOSE_ARGS=(--project-directory "${REPO_ROOT}" -f "${REPO_ROOT}/compose.yaml")

  HOST_UID="${HOST_UID:-$(id -u)}" HOST_GID="${HOST_GID:-$(id -g)}" HOST_KVM_GID="${HOST_KVM_GID_VALUE}" \
    docker compose "${COMPOSE_ARGS[@]}" run --rm "${SERVICE}" ./scripts/lib/build-seed.sh

  IMAGE_ARG="$(repo_relative_path "${IMAGE_PATH}")"
  OVERLAY_ARG="$(repo_relative_path "${OVERLAY_IMAGE}")"
  SEED_ARG="$(repo_relative_path "${BUILD_DIR}/seed.iso")"
  RUN_VM_ARGS=(
    ./scripts/lib/run-vm.sh
    --base-image "${IMAGE_ARG}"
    --overlay-image "${OVERLAY_ARG}"
    --seed-iso "${SEED_ARG}"
    --accelerator auto
  )

  log_info "Starting smoke VM via docker compose (${SERVICE})"
  HOST_UID="${HOST_UID:-$(id -u)}" HOST_GID="${HOST_GID:-$(id -g)}" HOST_KVM_GID="${HOST_KVM_GID_VALUE}" \
    nohup docker compose "${COMPOSE_ARGS[@]}" run --rm --service-ports "${SERVICE}" "${RUN_VM_ARGS[@]}" >"${VM_LOG}" 2>&1 &
else
  ensure_command qemu-system-x86_64
  ensure_command qemu-img
  "${SCRIPT_DIR}/lib/build-seed.sh"
  RUN_VM_ARGS=(
    --base-image "${IMAGE_PATH}"
    --overlay-image "${OVERLAY_IMAGE}"
    --seed-iso "${BUILD_DIR}/seed.iso"
    --accelerator auto
  )
  log_info "Starting smoke VM directly on host"
  nohup "${SCRIPT_DIR}/lib/run-vm.sh" "${RUN_VM_ARGS[@]}" >"${VM_LOG}" 2>&1 &
fi
VM_PID=$!

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
ATTEMPTS=180
if [[ ! -e /dev/kvm ]]; then
  ATTEMPTS=360
fi
SSH_CMD=(ssh "${SSH_OPTS[@]}" -i "${KEY_PATH}" -p "${SSH_PORT}" "${SSH_DESTINATION}")
SCP_CMD=(scp "${SSH_OPTS[@]}" -i "${KEY_PATH}" -P "${SSH_PORT}")

log_info "Waiting for SSH on ${SSH_HOST}:${SSH_PORT}"
for _ in $(seq 1 "${ATTEMPTS}"); do
  if "${SSH_CMD[@]}" 'echo ssh-ready' >/dev/null 2>&1; then
    log_info "SSH is ready"
    break
  fi
  sleep 2
done

if ! "${SSH_CMD[@]}" 'echo ssh-ready' >/dev/null 2>&1; then
  log_error "Timed out waiting for SSH"
  exit 1
fi

log_info "Waiting for cloud-init to settle"
cloud_init_ready=false
for attempt in $(seq 1 "${STABILIZATION_ATTEMPTS}"); do
  if "${SSH_CMD[@]}" \
    'command -v cloud-init >/dev/null 2>&1 && sudo cloud-init status --wait >/dev/null 2>&1 || true' \
    >/dev/null 2>&1; then
    cloud_init_ready=true
    break
  fi

  if [[ "${attempt}" -lt "${STABILIZATION_ATTEMPTS}" ]]; then
    log_warn "Cloud-init wait probe failed; retrying (${attempt}/${STABILIZATION_ATTEMPTS})"
    sleep 2
  fi
done

if [[ "${cloud_init_ready}" != "true" ]]; then
  log_warn "Unable to confirm cloud-init completion; continuing to stable SSH probe"
fi

log_info "Verifying SSH is stable"
stable_ssh_successes=0
for _ in $(seq 1 "${STABILIZATION_ATTEMPTS}"); do
  if "${SSH_CMD[@]}" 'true' >/dev/null 2>&1; then
    stable_ssh_successes=$((stable_ssh_successes + 1))
    if [[ "${stable_ssh_successes}" -ge "${REQUIRED_STABLE_SSH_PROBES}" ]]; then
      break
    fi
    sleep 1
    continue
  fi

  stable_ssh_successes=0
  sleep 2
done

if [[ "${stable_ssh_successes}" -lt "${REQUIRED_STABLE_SSH_PROBES}" ]]; then
  log_error "SSH did not stabilize after readiness probe"
  exit 1
fi

ensure_command curl
GOSS_VERSION="${GOSS_VERSION:-0.4.9}"
GOSS_BIN="${BUILD_DIR}/goss-${GOSS_VERSION}"
if [[ ! -x "${GOSS_BIN}" ]]; then
  BASE="https://github.com/goss-org/goss/releases/download/v${GOSS_VERSION}"
  curl -fsSL -o "${GOSS_BIN}" "${BASE}/goss-linux-amd64"
  curl -fsSL -o "${GOSS_BIN}.sha256" "${BASE}/goss-linux-amd64.sha256"
  HASH="$(awk '{print $1}' "${GOSS_BIN}.sha256")"
  echo "${HASH}  ${GOSS_BIN}" | sha256sum -c - >/dev/null
  chmod +x "${GOSS_BIN}"
fi

retry_scp "Uploading goss binary" "${SCP_CMD[@]}" "${GOSS_BIN}" "${SSH_DESTINATION}:/tmp/goss" >/dev/null
retry_scp "Uploading goss config" "${SCP_CMD[@]}" "${REPO_ROOT}/tests/goss.yaml" "${SSH_DESTINATION}:/tmp/goss.yaml" >/dev/null
retry_ssh_cmd "Running goss validation" "${SSH_CMD[@]}" \
  'sudo install -m 0755 /tmp/goss /usr/local/bin/goss && sudo goss -g /tmp/goss.yaml validate'

log_info "Smoke test passed"
