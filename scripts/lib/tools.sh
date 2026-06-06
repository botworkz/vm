#!/usr/bin/env bash
# scripts/lib/tools.sh — helpers for the botworkz/botwork sibling checkout.
# Source this file (after common.sh sets REPO_ROOT) to get:
#   BOTWORK_TOOLS_DIR       – path to the sibling checkout (workspace root)
#   botforge_image_ref()    – pinned botforge container image reference
#   run_botforge_container() – run botforge in a pinned container against this repo
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

run_botforge_container() {
  ensure_command docker

  local needs_docker_socket=false needs_kvm=false
  local extra_mounts=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --docker-sock)
        needs_docker_socket=true
        shift
        ;;
      --kvm)
        needs_kvm=true
        shift
        ;;
      --mount)
        extra_mounts+=("$(realpath -m "${2:-}")")
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  local host_uid host_gid host_kvm_gid_value botforge_image docker_args=()
  host_uid="${HOST_UID:-$(id -u)}"
  host_gid="${HOST_GID:-$(id -g)}"
  host_kvm_gid_value="$(host_kvm_gid)"
  botforge_image="$(botforge_image_ref)"

  docker_args=(
    --rm
    --user "${host_uid}:${host_gid}"
    -e HOME=/tmp
    -e XDG_CACHE_HOME=/tmp/.cache
    -e HOST_UID="${host_uid}"
    -e HOST_GID="${host_gid}"
    -e HOST_KVM_GID="${host_kvm_gid_value}"
    -v "${REPO_ROOT}:${REPO_ROOT}"
    -w "${REPO_ROOT}"
  )
  local extra_mount
  for extra_mount in "${extra_mounts[@]}"; do
    docker_args+=(-v "${extra_mount}:${extra_mount}")
  done

  if [[ "${needs_docker_socket}" == "true" ]]; then
    docker_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
    local docker_sock_gid
    docker_sock_gid="$(stat -c '%g' /var/run/docker.sock 2>/dev/null || true)"
    if [[ -n "${docker_sock_gid}" ]]; then
      docker_args+=(--group-add "${docker_sock_gid}")
    fi
  fi

  if [[ "${needs_kvm}" == "true" && -e /dev/kvm ]]; then
    docker_args+=(--device /dev/kvm)
  fi

  docker run "${docker_args[@]}" "${botforge_image}" "$@"
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
  run_botforge_container --docker-sock -- deps --out "${BUILD_DIR}/bin" --executable

  [[ -f "${BUILD_DIR}/bin/botwork-launcher" ]] \
    || die "botforge deps output missing botwork-launcher at ${BUILD_DIR}/bin/botwork-launcher"
  [[ -f "${BUILD_DIR}/bin/botwork-tools" ]] \
    || die "botforge deps output missing botwork-tools at ${BUILD_DIR}/bin/botwork-tools"

  chmod +x "${BUILD_DIR}/bin/botwork-launcher" "${BUILD_DIR}/bin/botwork-tools"
}
