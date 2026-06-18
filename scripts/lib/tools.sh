#!/usr/bin/env bash
# scripts/lib/tools.sh — helpers for the botworkz/botwork sibling checkout.
# Source this file (after common.sh sets REPO_ROOT) to get:
#   BOTWORK_TOOLS_DIR        – path to the sibling checkout (workspace root)
#   botforge_image_ref()     – pinned botforge container image reference
#   run_botforge_compose()   – run botforge via repo-root compose.yml
#   ensure_tools_sibling()   – die if sibling is missing/incomplete
#   build_tools_launcher()   – `cargo build --release --locked -p botwork-launcher`
#   build_tools_cli()        – `cargo build --release --locked -p botwork-tools`
set -euo pipefail

# NOTE: BOTWORK_TOOLS_DIR points to ../botwork (session-broker + Rust binaries).
BOTWORK_TOOLS_DIR="$(realpath -m "${BOTWORK_TOOLS_DIR:-${REPO_ROOT}/../botwork}")"

_image_ref_from_pin_file() {
  local pin_file="$1" image
  [[ -f "${pin_file}" ]] || die "missing image pin file: ${pin_file}"

  image="$(grep -m1 '^FROM[[:space:]]' "${pin_file}" | awk '{print $2}' || true)"
  [[ -n "${image}" ]] || die "invalid image pin in ${pin_file}"
  echo "${image}"
}

botforge_image_ref() {
  _image_ref_from_pin_file "${REPO_ROOT}/deps/container/botforge.Dockerfile"
}

host_kvm_gid() {
  local gid
  gid="${HOST_KVM_GID:-$(getent group kvm 2>/dev/null | cut -d: -f3 || true)}"
  if [[ -z "${gid}" ]]; then
    gid="993"
  fi
  echo "${gid}"
}

# run_botforge_compose <service> -- <args...>
#
# Services:
#   image-build — runs bash inside the botforge container, with /dev/kvm
#                 mounted for libguestfs acceleration. Used by scripts/pack.sh
#                 to invoke per-image build.sh files. Requires /dev/kvm.
#   test        — boots a packed qcow2 under qemu-system-x86_64. Requires /dev/kvm.
#   deps        — pulls release binaries + image tarballs via shasset. No KVM.
run_botforge_compose() {
  ensure_command docker
  docker compose version >/dev/null 2>&1 \
    || die "missing required Docker Compose plugin: 'docker compose' must be available"

  local svc="${1:-}"
  [[ -n "${svc}" ]] || die "missing botforge compose service (expected one of: image-build, test, deps)"
  shift || true
  [[ "${1:-}" == "--" ]] || die "run_botforge_compose requires '--' before botforge arguments"
  shift

  case "${svc}" in
    image-build|test|deps)
      ;;
    *)
      die "unknown botforge compose service: ${svc}"
      ;;
  esac

  if [[ "${svc}" != "deps" && ! -e /dev/kvm ]]; then
    die "botforge compose service '${svc}' requires /dev/kvm on the host"
  fi

  local host_uid host_gid host_kvm_gid_value botforge_image
  host_uid="${HOST_UID:-$(id -u)}"
  host_gid="${HOST_GID:-$(id -g)}"
  host_kvm_gid_value="$(host_kvm_gid)"
  botforge_image="$(botforge_image_ref)"

  export BOTFORGE_IMAGE="${botforge_image}"
  export REPO_ROOT="${REPO_ROOT}"
  export HOST_UID="${host_uid}"
  export HOST_GID="${host_gid}"
  export HOST_KVM_GID="${host_kvm_gid_value}"

  docker compose -f "${REPO_ROOT}/compose.yml" run --rm "${svc}" "$@"
}

ensure_tools_sibling() {
  if [[ ! -f "${BOTWORK_TOOLS_DIR}/Cargo.toml" ]]; then
    die "botworkz/botwork sibling not found or incomplete at ${BOTWORK_TOOLS_DIR} (missing Cargo.toml workspace root). " \
      "Clone https://github.com/botworkz/botwork next to this repo or set BOTWORK_TOOLS_DIR."
  fi
  if [[ ! -f "${BOTWORK_TOOLS_DIR}/Earthfile" ]]; then
    die "botworkz/botwork sibling not found or incomplete at ${BOTWORK_TOOLS_DIR} (missing Earthfile). " \
      "Clone https://github.com/botworkz/botwork next to this repo or set BOTWORK_TOOLS_DIR."
  fi
}

build_tools_launcher() {
  ensure_command cargo
  log_info "Building botwork-launcher in ${BOTWORK_TOOLS_DIR} …"
  (
    cd "${BOTWORK_TOOLS_DIR}"
    cargo build --release --locked -p botwork-launcher
  )
}

build_tools_cli() {
  ensure_command cargo
  log_info "Building botwork-tools CLI in ${BOTWORK_TOOLS_DIR} …"
  (
    cd "${BOTWORK_TOOLS_DIR}"
    cargo build --release --locked -p botwork-tools
  )
}

fetch_tools_binaries() {
  mkdir -p "${BUILD_DIR}/bin"
  log_info "Fetching botwork binaries via botforge ($(botforge_image_ref)) …"
  run_botforge_compose deps -- deps --out "${BUILD_DIR}/bin" --executable

  [[ -f "${BUILD_DIR}/bin/botwork-launcher" ]] \
    || die "botforge deps output missing botwork-launcher at ${BUILD_DIR}/bin/botwork-launcher"
  [[ -f "${BUILD_DIR}/bin/botwork-tools" ]] \
    || die "botforge deps output missing botwork-tools at ${BUILD_DIR}/bin/botwork-tools"

  chmod +x "${BUILD_DIR}/bin/botwork-launcher" "${BUILD_DIR}/bin/botwork-tools"
}
