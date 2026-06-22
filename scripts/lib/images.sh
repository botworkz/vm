#!/usr/bin/env bash
set -euo pipefail

if [[ "${_BOTWORK_IMAGES_LIB_SOURCED:-0}" == "1" ]]; then
  return 0
fi
_BOTWORK_IMAGES_LIB_SOURCED=1

# RFE #106 PR4 (botwork#118 + this PR): bootstrap retires. The
# `botwork-import.service` host-side oneshot calls
# `botwork-tools bootstrap` against admin-api, no bootstrap
# container needed.
BOTWORK_TOOLS_IMAGES="session-broker config-broker control-plane db-migrate admin-api admin-ui"
BOTWORKZ_MCP_IMAGES="mcp-echo"
# Third-party infra images pulled from upstream registries (not built by us).
# Currently postgres; pulled via the same registry-mode shasset path. Distinct
# variable so the sibling-mode codepath (BOTWORK_TOOLS_IMAGES_REF=sibling)
# doesn't accidentally try to build these from a sibling earthly target —
# there is no such target.
BOTWORK_THIRD_PARTY_IMAGES="postgres curl"
BOTWORK_BAKED_IMAGES="${BOTWORK_TOOLS_IMAGES} ${BOTWORKZ_MCP_IMAGES} ${BOTWORK_THIRD_PARTY_IMAGES}"
export BOTWORK_TOOLS_IMAGES BOTWORKZ_MCP_IMAGES BOTWORK_THIRD_PARTY_IMAGES BOTWORK_BAKED_IMAGES

# Returns 0 if the current environment looks like CI or a production build.
# Sibling-mode is for local iteration only and must be rejected in these envs.
_is_production_environment() {
  [[ "${CI:-}" == "true" ]] && return 0
  [[ "${GITHUB_ACTIONS:-}" == "true" ]] && return 0
  [[ -n "${BOTWORK_PRODUCTION_BUILD:-}" ]] && return 0
  return 1
}

# --- botwork-tools image mode helpers ---

images_mode() {
  local ref="${BOTWORK_TOOLS_IMAGES_REF:-}"
  case "${ref}" in
    ""|"registry") echo "registry" ;;
    "sibling")
      # Guard: sibling-mode is for local iteration only — reject in CI / production.
      if _is_production_environment; then
        die "BOTWORK_TOOLS_IMAGES_REF=sibling is not allowed in CI or production builds. Unset BOTWORK_TOOLS_IMAGES_REF (or set it to 'registry') and re-run."
      fi
      echo "sibling"
      ;;
    *) die "invalid BOTWORK_TOOLS_IMAGES_REF=${ref} (expected empty|sibling|registry)" ;;
  esac
}

# --- botworkz/mcp image mode helpers ---

botworkz_images_mode() {
  local ref="${BOTWORKZ_MCP_IMAGES_REF:-}"
  case "${ref}" in
    ""|"registry") echo "registry" ;;
    "sibling")
      # Guard: sibling-mode is for local iteration only — reject in CI / production.
      if _is_production_environment; then
        die "BOTWORKZ_MCP_IMAGES_REF=sibling is not allowed in CI or production builds. Unset BOTWORKZ_MCP_IMAGES_REF (or set it to 'registry') and re-run."
      fi
      echo "sibling"
      ;;
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

  # config-broker
  if [[ "${tools_mode}" == "sibling" ]]; then
    ensure_tools_sibling
    log_info "Building config-broker image from botworkz/botwork sibling …"
    ( cd "${BOTWORK_TOOLS_DIR}" && earthly +config-broker-image )
    _save_sibling_image_to_tarball "config-broker"
  else
    _fetch_registry_image_to_tarball "config-broker"
  fi

  # control-plane
  if [[ "${tools_mode}" == "sibling" ]]; then
    ensure_tools_sibling
    log_info "Building control-plane image from botworkz/botwork sibling …"
    ( cd "${BOTWORK_TOOLS_DIR}" && earthly +control-plane-image )
    _save_sibling_image_to_tarball "control-plane"
  else
    _fetch_registry_image_to_tarball "control-plane"
  fi

  # db-migrate — botwork's persistence-layer migration oneshot. Same
  # registry/sibling split as the other broker images. The Earthly target
  # in the botwork sibling is +db-migrate-image (matches the other
  # broker-image target names), produced by RFE 97 / PR #98.
  if [[ "${tools_mode}" == "sibling" ]]; then
    ensure_tools_sibling
    log_info "Building db-migrate image from botworkz/botwork sibling …"
    ( cd "${BOTWORK_TOOLS_DIR}" && earthly +db-migrate-image )
    _save_sibling_image_to_tarball "db-migrate"
  else
    _fetch_registry_image_to_tarball "db-migrate"
  fi

  # bootstrap container: retired under RFE #106 PR4 (botwork#118 +
  # this PR). The host-side `botwork-import.service` oneshot calls
  # `botwork-tools bootstrap` directly against admin-api, so there's
  # no bootstrap image to fetch any more. Left as a comment marker so
  # the diff is greppable.

  # admin-api — botwork's HTTP+JSON CRUD service over the entity
  # layer (RFE #106 PR1). v0 ships only `GET /admin/api/v1/health`;
  # entity handlers land in RFE #106 PR2. Same registry/sibling split
  # as the other broker images. The Earthly target in the botwork
  # sibling is +admin-api-image (matches the other broker-image
  # target names). systemd unit ordering on the deployed VM is
  # After=botwork-db-migrate (schema present), but NOT
  # After=botwork-bootstrap (no seed data needed for the health
  # endpoint — admin-api itself will be the future writer of that
  # seed data once bootstrap retires under RFE #106).
  if [[ "${tools_mode}" == "sibling" ]]; then
    ensure_tools_sibling
    log_info "Building admin-api image from botworkz/botwork sibling …"
    ( cd "${BOTWORK_TOOLS_DIR}" && earthly +admin-api-image )
    _save_sibling_image_to_tarball "admin-api"
  else
    _fetch_registry_image_to_tarball "admin-api"
  fi

  # admin-ui — botwork's operator-facing Leptos panel (RFE #106
  # follow-up). Static bundle baked into the binary via include_dir!;
  # the runtime container has no DB connection (it talks to admin-api
  # over the docker network). Same registry/sibling split as the
  # other broker images. The Earthly target in the botwork sibling
  # is +admin-ui-image. systemd unit ordering on the deployed VM is
  # just After=network-online + docker + botwork-network — NOT
  # After=botwork-db-migrate, because admin-ui doesn't touch postgres.
  if [[ "${tools_mode}" == "sibling" ]]; then
    ensure_tools_sibling
    log_info "Building admin-ui image from botworkz/botwork sibling …"
    ( cd "${BOTWORK_TOOLS_DIR}" && earthly +admin-ui-image )
    _save_sibling_image_to_tarball "admin-ui"
  else
    _fetch_registry_image_to_tarball "admin-ui"
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

  # postgres — upstream third-party image; no sibling build path. Always
  # pulled via botforge deps from the oci:// digest pinned in shasset.yaml.
  # The image-loader retags it to botwork/postgres:local on first boot
  # (so the systemd unit references a stable local tag, same posture as
  # the broker images).
  _fetch_registry_image_to_tarball "postgres"

  # curl — upstream third-party image used ONLY by goss probes inside
  # the VM (every `docker run --rm --network botwork-internal botwork/curl:local`
  # call). Baked so the probes don't pull docker.io live on every test
  # run; Docker Hub's anonymous-token endpoint returns 404 ~1/N which
  # was the flake behind the recent main-branch CI failures.
  _fetch_registry_image_to_tarball "curl"
}
