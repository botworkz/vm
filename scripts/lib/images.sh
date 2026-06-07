#!/usr/bin/env bash
set -euo pipefail

if [[ "${_BOTWORK_IMAGES_LIB_SOURCED:-0}" == "1" ]]; then
  return 0
fi
_BOTWORK_IMAGES_LIB_SOURCED=1

BOTWORK_TOOLS_IMAGES="session-broker"
BOTWORKZ_MCP_IMAGES="mcp-echo"
BOTWORK_BAKED_IMAGES="${BOTWORK_TOOLS_IMAGES} ${BOTWORKZ_MCP_IMAGES}"
export BOTWORK_TOOLS_IMAGES BOTWORKZ_MCP_IMAGES BOTWORK_BAKED_IMAGES

# --- botwork-tools image mode helpers ---

images_mode() {
  local ref="${BOTWORK_TOOLS_IMAGES_REF:-}"
  case "${ref}" in
    ""|"registry") echo "registry" ;;
    "sibling")     echo "sibling" ;;
    *) die "invalid BOTWORK_TOOLS_IMAGES_REF=${ref} (expected empty|sibling|registry)" ;;
  esac
}

# --- botworkz/mcp image mode helpers ---

botworkz_images_mode() {
  local ref="${BOTWORKZ_MCP_IMAGES_REF:-}"
  case "${ref}" in
    ""|"registry") echo "registry" ;;
    "sibling")     echo "sibling" ;;
    *) die "invalid BOTWORKZ_MCP_IMAGES_REF=${ref} (expected empty|sibling|registry)" ;;
  esac
}

# --- sibling-mode helpers (kept) ---

_save_sibling_image_to_tarball() {
  local svc="$1"
  ensure_command docker
  log_info "Saving botwork/${svc}:local to ${BUILD_DIR}/images/baked/${svc}.tar …"
  docker save "botwork/${svc}:local" -o "${BUILD_DIR}/images/baked/${svc}.tar"
}

# --- registry-mode helper: one botforge-deps call per oci:// asset ---

_fetch_registry_image_to_tarball() {
  local svc="$1"
  log_info "Fetching ${svc} via botforge ($(botforge_image_ref)) → ${BUILD_DIR}/images/baked/${svc}.tar …"
  run_botforge_compose deps -- \
    deps --out "${BUILD_DIR}/images/baked" "${svc}"
  [[ -f "${BUILD_DIR}/images/baked/${svc}.tar" ]] \
    || die "botforge deps did not produce expected tarball: ${BUILD_DIR}/images/baked/${svc}.tar"
}

ensure_images() {
  local tools_mode botworkz_mode
  tools_mode="$(images_mode)"
  botworkz_mode="$(botworkz_images_mode)"

  if [[ "${tools_mode}" == "sibling" || "${botworkz_mode}" == "sibling" ]]; then
    ensure_command earthly
  fi

  mkdir -p "${BUILD_DIR}/images/baked"

  # session-broker
  if [[ "${tools_mode}" == "sibling" ]]; then
    ensure_tools_sibling
    log_info "Building session-broker image from botworkz/botwork sibling …"
    ( cd "${BOTWORK_TOOLS_DIR}" && earthly +session-broker-image )
    _save_sibling_image_to_tarball "session-broker"
  else
    _fetch_registry_image_to_tarball "session-broker"
  fi

  # mcp-echo
  if [[ "${botworkz_mode}" == "sibling" ]]; then
    ensure_botworkz_sibling
    log_info "Building botworkz/mcp container images from sibling checkout …"
    ( cd "${BOTWORKZ_MCP_DIR}" && earthly +mcp-echo-image )
    _save_sibling_image_to_tarball "mcp-echo"
  else
    _fetch_registry_image_to_tarball "mcp-echo"
  fi
}
