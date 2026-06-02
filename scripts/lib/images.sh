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
  if [[ -z "${ref}" || "${ref}" == "registry" || "${ref}" == ghcr.io/* ]]; then
    echo "registry"
    return 0
  fi
  if [[ "${ref}" == "sibling" ]]; then
    echo "sibling"
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
  echo "${BOTWORK_TOOLS_IMAGES_VERSION:-${BOTWORK_TOOLS_IMAGES_VERSION_LOCK}}"
}

# --- packer-tools image mode helpers ---

packer_tools_mode() {
  local ref="${BOTWORK_PACKER_TOOLS_REF:-}"
  if [[ -z "${ref}" || "${ref}" == "registry" || "${ref}" == ghcr.io/* ]]; then
    echo "registry"
    return 0
  fi
  if [[ "${ref}" == "sibling" ]]; then
    echo "sibling"
    return 0
  fi
  die "invalid BOTWORK_PACKER_TOOLS_REF=${ref} (expected empty|sibling|registry|ghcr.io/...)"
}

_packer_tools_registry_prefix() {
  local ref="${BOTWORK_PACKER_TOOLS_REF:-}"
  if [[ "${ref}" == ghcr.io/* ]]; then
    echo "${ref%/}"
  else
    echo "ghcr.io/botworkz/tools"
  fi
}

# --- botworkz/mcp image mode helpers ---

botworkz_images_mode() {
  local ref="${BOTWORKZ_MCP_IMAGES_REF:-}"
  if [[ -z "${ref}" || "${ref}" == "registry" || "${ref}" == ghcr.io/* ]]; then
    echo "registry"
    return 0
  fi
  if [[ "${ref}" == "sibling" ]]; then
    echo "sibling"
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
  echo "${BOTWORKZ_MCP_IMAGES_VERSION:-${BOTWORKZ_MCP_IMAGES_VERSION_LOCK}}"
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

_packer_tools_version() {
  echo "${BOTWORK_PACKER_TOOLS_VERSION:-${BOTWORK_PACKER_TOOLS_IMAGES_VERSION_LOCK}}"
}

_image_pin_file_for() {
  local svc="$1"
  case "${svc}" in
    packer-tools) echo "${REPO_ROOT}/deps/container/packer-tools.Dockerfile" ;;
    session-broker) echo "${REPO_ROOT}/deps/container/session-broker.Dockerfile" ;;
    mcp-echo) echo "${REPO_ROOT}/deps/container/mcp-echo.Dockerfile" ;;
    *) die "unknown image service for digest pin: ${svc}" ;;
  esac
}

_image_digest_pin() {
  local svc="$1"
  local pin_file from_line digest
  pin_file="$(_image_pin_file_for "${svc}")"
  [[ -f "${pin_file}" ]] || die "missing digest pin Dockerfile for ${svc}: ${pin_file}"

  from_line="$(grep -m1 '^FROM[[:space:]]' "${pin_file}" || true)"
  digest="$(echo "${from_line}" | sed -nE 's/.*@(sha256:[A-Fa-f0-9]{64}).*/\1/p')"
  [[ -n "${digest}" ]] || die "missing digest pin in ${pin_file} for ${svc}"
  echo "${digest}"
}

_pull_packer_tools_local_registry() {
  local version prefix upstream_image digest
  version="$(_packer_tools_version)"
  prefix="$(_packer_tools_registry_prefix)"
  digest="$(_image_digest_pin "packer-tools")"
  upstream_image="${prefix}/packer-tools@${digest}"
  log_info "Pulling ${prefix}/packer-tools:${version} by digest ${digest} and tagging botwork/packer-tools:local …"
  docker pull "${upstream_image}"
  docker tag "${upstream_image}" "botwork/packer-tools:local"
}

ensure_images_loaded() {
  ensure_command docker
  if _all_local_images_present; then
    log_info "All botwork local images already loaded."
    return 0
  fi

  local packer_tools_mode_value tools_mode botworkz_mode svc prefix version upstream_image digest
  packer_tools_mode_value="$(packer_tools_mode)"
  tools_mode="$(images_mode)"
  botworkz_mode="$(botworkz_images_mode)"

  if [[ "${packer_tools_mode_value}" == "sibling" || "${tools_mode}" == "sibling" || "${botworkz_mode}" == "sibling" ]]; then
    ensure_command earthly
  fi

  # --- packer-tools: sibling (botworkz/tools) or registry ---
  if [[ "${packer_tools_mode_value}" == "sibling" ]]; then
    ensure_packer_tools_sibling
    log_info "Building packer-tools image from botworkz/tools sibling …"
    (
      cd "${BOTWORK_PACKER_TOOLS_DIR}"
      earthly +packer-tools-image
    )
  else
    _pull_packer_tools_local_registry
  fi

  # --- session-broker: built from botworkz/botwork sibling or pulled from registry ---
  if [[ "${tools_mode}" == "sibling" ]]; then
    ensure_tools_sibling
    log_info "Building session-broker image from botworkz/botwork sibling …"
    (
      cd "${BOTWORK_TOOLS_DIR}"
      earthly +session-broker-image
    )
  else
    prefix="$(_images_registry_prefix)"
    version="$(_images_version)"
    digest="$(_image_digest_pin "session-broker")"
    upstream_image="${prefix}/session-broker@${digest}"
    log_info "Pulling ${prefix}/session-broker:${version} by digest ${digest} and tagging botwork/session-broker:local …"
    docker pull "${upstream_image}"
    docker tag "${upstream_image}" "botwork/session-broker:local"
  fi

  # --- botworkz/mcp images (mcp-echo) ---
  if [[ "${botworkz_mode}" == "sibling" ]]; then
    ensure_botworkz_sibling
    log_info "Building botworkz/mcp container images from sibling checkout …"
    (
      cd "${BOTWORKZ_MCP_DIR}"
      earthly +mcp-echo-image
    )
  else
    prefix="$(_botworkz_images_registry_prefix)"
    version="$(_botworkz_images_version)"
    for svc in ${BOTWORKZ_MCP_IMAGES}; do
      digest="$(_image_digest_pin "${svc}")"
      upstream_image="${prefix}/${svc}@${digest}"
      log_info "Pulling ${prefix}/${svc}:${version} by digest ${digest} and tagging botwork/${svc}:local …"
      docker pull "${upstream_image}"
      docker tag "${upstream_image}" "botwork/${svc}:local"
    done
  fi
}

ensure_images() {
  ensure_command docker

  local packer_tools_mode_value tools_mode botworkz_mode svc prefix version upstream_image digest
  packer_tools_mode_value="$(packer_tools_mode)"
  tools_mode="$(images_mode)"
  botworkz_mode="$(botworkz_images_mode)"

  if [[ "${packer_tools_mode_value}" == "sibling" || "${tools_mode}" == "sibling" || "${botworkz_mode}" == "sibling" ]]; then
    ensure_command earthly
  fi

  mkdir -p "${BUILD_DIR}/images/baked"

  # --- packer-tools: sibling (botworkz/tools) or registry ---
  if [[ "${packer_tools_mode_value}" == "sibling" ]]; then
    ensure_packer_tools_sibling
    log_info "Building packer-tools image from botworkz/tools sibling …"
    (
      cd "${BOTWORK_PACKER_TOOLS_DIR}"
      earthly +packer-tools-image
    )
  else
    _pull_packer_tools_local_registry
  fi
  log_info "Saving botwork/packer-tools:local to ${BUILD_DIR}/images/baked/packer-tools.tar …"
  docker save "botwork/packer-tools:local" -o "${BUILD_DIR}/images/baked/packer-tools.tar"

  # --- session-broker: built from botworkz/botwork sibling or pulled from registry ---
  if [[ "${tools_mode}" == "sibling" ]]; then
    ensure_tools_sibling
    log_info "Building session-broker image from botworkz/botwork sibling …"
    (
      cd "${BOTWORK_TOOLS_DIR}"
      earthly +session-broker-image
    )
  else
    prefix="$(_images_registry_prefix)"
    version="$(_images_version)"
    digest="$(_image_digest_pin "session-broker")"
    upstream_image="${prefix}/session-broker@${digest}"
    log_info "Pulling ${prefix}/session-broker:${version} by digest ${digest}, tagging local image, and saving tarball …"
    docker pull "${upstream_image}"
    docker tag "${upstream_image}" "botwork/session-broker:local"
  fi
  log_info "Saving botwork/session-broker:local to ${BUILD_DIR}/images/baked/session-broker.tar …"
  docker save "botwork/session-broker:local" -o "${BUILD_DIR}/images/baked/session-broker.tar"

  # --- botworkz/mcp images (baked) ---
  if [[ "${botworkz_mode}" == "sibling" ]]; then
    ensure_botworkz_sibling
    log_info "Building botworkz/mcp container images from sibling checkout …"
    (
      cd "${BOTWORKZ_MCP_DIR}"
      earthly +mcp-echo-image
    )
    for svc in ${BOTWORKZ_MCP_IMAGES}; do
      log_info "Saving botwork/${svc}:local to ${BUILD_DIR}/images/baked/${svc}.tar …"
      docker save "botwork/${svc}:local" -o "${BUILD_DIR}/images/baked/${svc}.tar"
    done
  else
    prefix="$(_botworkz_images_registry_prefix)"
    version="$(_botworkz_images_version)"
    for svc in ${BOTWORKZ_MCP_IMAGES}; do
      digest="$(_image_digest_pin "${svc}")"
      upstream_image="${prefix}/${svc}@${digest}"
      log_info "Pulling ${prefix}/${svc}:${version} by digest ${digest}, tagging local image, and saving tarball …"
      docker pull "${upstream_image}"
      docker tag "${upstream_image}" "botwork/${svc}:local"
      docker save "botwork/${svc}:local" -o "${BUILD_DIR}/images/baked/${svc}.tar"
    done
  fi
}
