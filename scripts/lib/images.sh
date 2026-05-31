#!/usr/bin/env bash
set -euo pipefail

if [[ "${_BOTWORK_IMAGES_LIB_SOURCED:-0}" == "1" ]]; then
  return 0
fi
_BOTWORK_IMAGES_LIB_SOURCED=1

BOTWORK_TOOLS_IMAGES="packer-tools session-broker"
BOTWORKZ_MCP_IMAGES="mcp-echo"
BOTWORK_BAKED_IMAGES="${BOTWORK_TOOLS_IMAGES} ${BOTWORKZ_MCP_IMAGES}"
export BOTWORK_TOOLS_IMAGES BOTWORKZ_MCP_IMAGES BOTWORK_BAKED_IMAGES

# --- botwork-tools image mode helpers ---

images_mode() {
  local ref="${BOTWORK_TOOLS_IMAGES_REF:-}"
  if [[ -z "${ref}" || "${ref}" == "sibling" ]]; then
    echo "sibling"
    return 0
  fi
  if [[ "${ref}" == "registry" || "${ref}" == ghcr.io/* ]]; then
    echo "registry"
    return 0
  fi
  die "invalid BOTWORK_TOOLS_IMAGES_REF=${ref} (expected empty|sibling|registry|ghcr.io/...)"
}

_images_registry_prefix() {
  local ref="${BOTWORK_TOOLS_IMAGES_REF:-}"
  if [[ "${ref}" == ghcr.io/* ]]; then
    echo "${ref%/}"
  else
    echo "ghcr.io/botworkz/botwork"
  fi
}

_images_version() {
  echo "${BOTWORK_TOOLS_IMAGES_VERSION:-latest}"
}

# --- botworkz/mcp image mode helpers ---

botworkz_images_mode() {
  local ref="${BOTWORKZ_MCP_IMAGES_REF:-}"
  if [[ -z "${ref}" || "${ref}" == "sibling" ]]; then
    echo "sibling"
    return 0
  fi
  if [[ "${ref}" == "registry" || "${ref}" == ghcr.io/* ]]; then
    echo "registry"
    return 0
  fi
  die "invalid BOTWORKZ_MCP_IMAGES_REF=${ref} (expected empty|sibling|registry|ghcr.io/...)"
}

_botworkz_images_registry_prefix() {
  local ref="${BOTWORKZ_MCP_IMAGES_REF:-}"
  if [[ "${ref}" == ghcr.io/* ]]; then
    echo "${ref%/}"
  else
    echo "ghcr.io/botworkz/mcp"
  fi
}

_botworkz_images_version() {
  echo "${BOTWORKZ_MCP_IMAGES_VERSION:-latest}"
}

# --- shared helpers ---

_local_tag_for() {
  echo "botwork/${1}:local"
}

_all_local_images_present() {
  local svc
  for svc in ${BOTWORK_BAKED_IMAGES}; do
    if ! docker image inspect "$(_local_tag_for "${svc}")" >/dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}

# packer-tools is defined in THIS repo (containers/packer-tools) and is always
# built locally, regardless of BOTWORK_TOOLS_IMAGES_REF. That flag only governs
# how session-broker and the botwork-tools binaries are produced.
_build_packer_tools_local() {
  log_info "Building packer-tools image from in-repo containers/packer-tools …"
  docker build -t botwork/packer-tools:local \
    -f "${REPO_ROOT}/containers/packer-tools/Dockerfile" \
    "${REPO_ROOT}/containers/packer-tools"
}

ensure_images_loaded() {
  ensure_command docker
  if _all_local_images_present; then
    log_info "All botwork local images already loaded."
    return 0
  fi

  local tools_mode botworkz_mode svc prefix version upstream_image
  tools_mode="$(images_mode)"
  botworkz_mode="$(botworkz_images_mode)"

  # --- packer-tools: always built from this repo's containers/ dir ---
  _build_packer_tools_local

  # --- session-broker: built from botworkz/botwork sibling containers/ ---
  if [[ "${tools_mode}" == "sibling" ]]; then
    ensure_tools_sibling
    log_info "Building session-broker image from botworkz/botwork sibling …"
    make -C "${BOTWORK_TOOLS_DIR}/containers" session-broker
  else
    prefix="$(_images_registry_prefix)"
    version="$(_images_version)"
    upstream_image="${prefix}/session-broker:${version}"
    log_info "Pulling ${upstream_image} and tagging botwork/session-broker:local …"
    docker pull "${upstream_image}"
    docker tag "${upstream_image}" "botwork/session-broker:local"
  fi

  # --- botworkz/mcp images (mcp-echo) ---
  if [[ "${botworkz_mode}" == "sibling" ]]; then
    ensure_botworkz_sibling
    log_info "Building botworkz/mcp container images from sibling checkout …"
    make -C "$(botworkz_containers_dir)" mcp-echo
  else
    prefix="$(_botworkz_images_registry_prefix)"
    version="$(_botworkz_images_version)"
    for svc in ${BOTWORKZ_MCP_IMAGES}; do
      upstream_image="${prefix}/${svc}:${version}"
      log_info "Pulling ${upstream_image} and tagging botwork/${svc}:local …"
      docker pull "${upstream_image}"
      docker tag "${upstream_image}" "botwork/${svc}:local"
    done
  fi
}

ensure_images() {
  ensure_command docker

  local tools_mode botworkz_mode svc prefix version upstream_image
  tools_mode="$(images_mode)"
  botworkz_mode="$(botworkz_images_mode)"

  mkdir -p "${BUILD_DIR}/images/baked"

  # --- packer-tools: always built from this repo's containers/ dir ---
  _build_packer_tools_local
  log_info "Saving botwork/packer-tools:local to ${BUILD_DIR}/images/baked/packer-tools.tar …"
  docker save "botwork/packer-tools:local" -o "${BUILD_DIR}/images/baked/packer-tools.tar"

  # --- session-broker: built from botworkz/botwork sibling containers/ ---
  if [[ "${tools_mode}" == "sibling" ]]; then
    ensure_tools_sibling
    log_info "Building session-broker image from botworkz/botwork sibling …"
    make -C "${BOTWORK_TOOLS_DIR}/containers" session-broker
  else
    prefix="$(_images_registry_prefix)"
    version="$(_images_version)"
    upstream_image="${prefix}/session-broker:${version}"
    log_info "Pulling ${upstream_image}, tagging local image, and saving tarball …"
    docker pull "${upstream_image}"
    docker tag "${upstream_image}" "botwork/session-broker:local"
  fi
  log_info "Saving botwork/session-broker:local to ${BUILD_DIR}/images/baked/session-broker.tar …"
  docker save "botwork/session-broker:local" -o "${BUILD_DIR}/images/baked/session-broker.tar"

  # --- botworkz/mcp images (baked) ---
  if [[ "${botworkz_mode}" == "sibling" ]]; then
    ensure_botworkz_sibling
    log_info "Building botworkz/mcp container images from sibling checkout …"
    make -C "$(botworkz_containers_dir)" mcp-echo
    for svc in ${BOTWORKZ_MCP_IMAGES}; do
      log_info "Saving botwork/${svc}:local to ${BUILD_DIR}/images/baked/${svc}.tar …"
      docker save "botwork/${svc}:local" -o "${BUILD_DIR}/images/baked/${svc}.tar"
    done
  else
    prefix="$(_botworkz_images_registry_prefix)"
    version="$(_botworkz_images_version)"
    for svc in ${BOTWORKZ_MCP_IMAGES}; do
      upstream_image="${prefix}/${svc}:${version}"
      log_info "Pulling ${upstream_image}, tagging local image, and saving tarball …"
      docker pull "${upstream_image}"
      docker tag "${upstream_image}" "botwork/${svc}:local"
      docker save "botwork/${svc}:local" -o "${BUILD_DIR}/images/baked/${svc}.tar"
    done
  fi
}
