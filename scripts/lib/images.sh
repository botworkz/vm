#!/usr/bin/env bash
set -euo pipefail

if [[ "${_BOTWORK_IMAGES_LIB_SOURCED:-0}" == "1" ]]; then
  return 0
fi
_BOTWORK_IMAGES_LIB_SOURCED=1

BOTWORK_TOOLS_IMAGES="packer-tools session-broker"
BOTWORKZ_MCP_IMAGES="mcp-echo"
BOTWORK_MCP_PAYLOAD_IMAGES="mcp-exec-bash mcp-exec-jq mcp-exec-node mcp-exec-python mcp-fetch mcp-fs mcp-git"
BOTWORK_BAKED_IMAGES="${BOTWORK_TOOLS_IMAGES} ${BOTWORKZ_MCP_IMAGES}"
BOTWORK_PAYLOAD_IMAGES="${BOTWORK_MCP_PAYLOAD_IMAGES}"
BOTWORK_ALL_IMAGES="${BOTWORK_BAKED_IMAGES} ${BOTWORK_PAYLOAD_IMAGES}"
export BOTWORK_TOOLS_IMAGES BOTWORKZ_MCP_IMAGES BOTWORK_MCP_PAYLOAD_IMAGES BOTWORK_BAKED_IMAGES BOTWORK_PAYLOAD_IMAGES BOTWORK_ALL_IMAGES

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
    # Repository name remains botspace-tools, but GHCR image namespace moved to
    # botwork-tools with the tooling-layer rename.
    echo "ghcr.io/phlax/botwork-tools"
  fi
}

_images_version() {
  echo "${BOTWORK_TOOLS_IMAGES_VERSION:-latest}"
}

# --- botwork-mcp image mode helpers ---

botwork_images_mode() {
  local ref="${BOTWORK_MCP_IMAGES_REF:-}"
  if [[ -z "${ref}" || "${ref}" == "sibling" ]]; then
    echo "sibling"
    return 0
  fi
  if [[ "${ref}" == "registry" || "${ref}" == ghcr.io/* ]]; then
    echo "registry"
    return 0
  fi
  die "invalid BOTWORK_MCP_IMAGES_REF=${ref} (expected empty|sibling|registry|ghcr.io/...)"
}

_botwork_images_registry_prefix() {
  local ref="${BOTWORK_MCP_IMAGES_REF:-}"
  if [[ "${ref}" == ghcr.io/* ]]; then
    echo "${ref%/}"
  else
    echo "ghcr.io/phlax/botwork-mcp"
  fi
}

_botwork_images_version() {
  echo "${BOTWORK_MCP_IMAGES_VERSION:-latest}"
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
  local svc="$1"
  if [[ " ${BOTWORKZ_MCP_IMAGES} ${BOTWORK_MCP_PAYLOAD_IMAGES} " == *" ${svc} "* ]]; then
    echo "botwork/${svc}:local"
  else
    echo "botwork/${svc}:local"
  fi
}

_all_local_images_present() {
  local svc
  for svc in ${BOTWORK_ALL_IMAGES}; do
    if ! docker image inspect "$(_local_tag_for "${svc}")" >/dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}

ensure_images_loaded() {
  ensure_command docker
  if _all_local_images_present; then
    log_info "All botwork local images already loaded."
    return 0
  fi

  local tools_mode botwork_mode botworkz_mode svc prefix version upstream_image
  local -a botwork_tools_targets
  tools_mode="$(images_mode)"
  botwork_mode="$(botwork_images_mode)"
  botworkz_mode="$(botworkz_images_mode)"

  # --- botwork-tools images ---
  if [[ "${tools_mode}" == "sibling" ]]; then
    ensure_tools_sibling
    log_info "Building botwork-tools container images from sibling checkout …"
    read -ra botwork_tools_targets <<< "${BOTWORK_TOOLS_IMAGES}"
    make -C "${BOTWORK_TOOLS_DIR}/containers" "${botwork_tools_targets[@]}"
  else
    prefix="$(_images_registry_prefix)"
    version="$(_images_version)"
    for svc in ${BOTWORK_TOOLS_IMAGES}; do
      upstream_image="${prefix}/${svc}:${version}"
      log_info "Pulling ${upstream_image} and tagging botwork/${svc}:local …"
      docker pull "${upstream_image}"
      docker tag "${upstream_image}" "botwork/${svc}:local"
    done
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

  # --- botwork-mcp payload images ---
  if [[ "${botwork_mode}" == "sibling" ]]; then
    ensure_botwork_sibling
    log_info "Building botwork-mcp container images from sibling checkout …"
    make -C "$(botwork_containers_dir)" containers
  else
    prefix="$(_botwork_images_registry_prefix)"
    version="$(_botwork_images_version)"
    for svc in ${BOTWORK_MCP_PAYLOAD_IMAGES}; do
      upstream_image="${prefix}/${svc}:${version}"
      log_info "Pulling ${upstream_image} and tagging botwork/${svc}:local …"
      docker pull "${upstream_image}"
      docker tag "${upstream_image}" "botwork/${svc}:local"
    done
  fi
}

ensure_images() {
  ensure_command docker

  local tools_mode botwork_mode botworkz_mode svc prefix version upstream_image
  local -a botwork_tools_targets
  tools_mode="$(images_mode)"
  botwork_mode="$(botwork_images_mode)"
  botworkz_mode="$(botworkz_images_mode)"

  mkdir -p "${BUILD_DIR}/images/baked" "${BUILD_DIR}/images/payload"

  # --- botwork-tools images ---
  if [[ "${tools_mode}" == "sibling" ]]; then
    ensure_tools_sibling
    log_info "Building botwork-tools container images from sibling checkout …"
    read -ra botwork_tools_targets <<< "${BOTWORK_TOOLS_IMAGES}"
    make -C "${BOTWORK_TOOLS_DIR}/containers" "${botwork_tools_targets[@]}"
    for svc in ${BOTWORK_TOOLS_IMAGES}; do
      log_info "Saving botwork/${svc}:local to ${BUILD_DIR}/images/baked/${svc}.tar …"
      docker save "botwork/${svc}:local" -o "${BUILD_DIR}/images/baked/${svc}.tar"
    done
  else
    prefix="$(_images_registry_prefix)"
    version="$(_images_version)"
    for svc in ${BOTWORK_TOOLS_IMAGES}; do
      upstream_image="${prefix}/${svc}:${version}"
      log_info "Pulling ${upstream_image}, tagging local image, and saving tarball …"
      docker pull "${upstream_image}"
      docker tag "${upstream_image}" "botwork/${svc}:local"
      docker save "botwork/${svc}:local" -o "${BUILD_DIR}/images/baked/${svc}.tar"
    done
  fi

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

  # --- botwork-mcp payload images ---
  if [[ "${botwork_mode}" == "sibling" ]]; then
    ensure_botwork_sibling
    log_info "Building botwork-mcp container images from sibling checkout …"
    make -C "$(botwork_containers_dir)" containers
    for svc in ${BOTWORK_MCP_PAYLOAD_IMAGES}; do
      log_info "Saving botwork/${svc}:local to ${BUILD_DIR}/images/payload/${svc}.tar …"
      docker save "botwork/${svc}:local" -o "${BUILD_DIR}/images/payload/${svc}.tar"
    done
  else
    prefix="$(_botwork_images_registry_prefix)"
    version="$(_botwork_images_version)"
    for svc in ${BOTWORK_MCP_PAYLOAD_IMAGES}; do
      upstream_image="${prefix}/${svc}:${version}"
      log_info "Pulling ${upstream_image}, tagging local image, and saving tarball …"
      docker pull "${upstream_image}"
      docker tag "${upstream_image}" "botwork/${svc}:local"
      docker save "botwork/${svc}:local" -o "${BUILD_DIR}/images/payload/${svc}.tar"
    done
  fi
}
