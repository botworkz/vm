#!/usr/bin/env bash
# scripts/lib/tools.sh — helpers for the botworkz/botwork sibling checkout.
# Source this file (after common.sh sets REPO_ROOT) to get:
#   BOTWORK_TOOLS_DIR       – path to the sibling checkout (workspace root)
#   BOTWORK_PACKER_TOOLS_DIR – path to botworkz/tools sibling (packer-tools image producer)
#   ensure_tools_sibling()   – die if sibling is missing/incomplete
#   ensure_packer_tools_sibling() – die if packer-tools sibling is missing/incomplete
#   build_tools_launcher()   – `cargo build --release --locked -p botwork-launcher`
#   build_tools_cli()        – `cargo build --release --locked -p botwork-tools`
set -euo pipefail

# NOTE: BOTWORK_TOOLS_DIR points to ../botwork (session-broker + Rust binaries).
# The separate packer-tools image producer repo is ../tools via BOTWORK_PACKER_TOOLS_DIR.
BOTWORK_TOOLS_DIR="$(realpath -m "${BOTWORK_TOOLS_DIR:-${REPO_ROOT}/../botwork}")"
BOTWORK_PACKER_TOOLS_DIR="$(realpath -m "${BOTWORK_PACKER_TOOLS_DIR:-${REPO_ROOT}/../tools}")"

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

ensure_packer_tools_sibling() {
  if [[ ! -f "${BOTWORK_PACKER_TOOLS_DIR}/Earthfile" ]]; then
    die "botworkz/tools sibling not found or incomplete at ${BOTWORK_PACKER_TOOLS_DIR} (missing Earthfile). " \
      "Clone https://github.com/botworkz/tools next to this repo or set BOTWORK_PACKER_TOOLS_DIR."
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
  ensure_command curl
  ensure_command sha256sum

  local version base_url
  version="${BOTWORK_TOOLS_VERSION:-${BOTWORK_TOOLS_VERSION_LOCK}}"
  [[ -n "${version}" ]] || die "BOTWORK_TOOLS_VERSION_LOCK is empty; set deps.lock before fetching binaries"
  base_url="https://github.com/botworkz/botwork/releases/download/v${version}"

  verify_sha256() {
    local file_path="$1"
    local expected_sha="$2"
    local label="$3"
    local actual_sha

    if [[ -z "${expected_sha}" ]]; then
      log_warn "No sha256 pin for ${label}; skipping verification (run ./scripts/update-deps.sh to populate deps.lock)."
      return 0
    fi

    actual_sha="$(sha256sum "${file_path}" | awk '{print $1}')"
    [[ "${actual_sha}" == "${expected_sha}" ]] \
      || die "sha256 mismatch for ${label}: expected ${expected_sha}, got ${actual_sha}"
  }

  log_info "Downloading botwork-launcher from ${base_url} …"
  curl -fSL -o "${BUILD_DIR}/bin/botwork-launcher" "${base_url}/botwork-launcher"
  verify_sha256 "${BUILD_DIR}/bin/botwork-launcher" "${BOTWORK_TOOLS_SHA256_botwork_launcher:-}" "botwork-launcher"
  chmod +x "${BUILD_DIR}/bin/botwork-launcher"

  log_info "Downloading botwork-tools from ${base_url} …"
  curl -fSL -o "${BUILD_DIR}/bin/botwork-tools" "${base_url}/botwork-tools"
  verify_sha256 "${BUILD_DIR}/bin/botwork-tools" "${BOTWORK_TOOLS_SHA256_botwork_tools:-}" "botwork-tools"
  chmod +x "${BUILD_DIR}/bin/botwork-tools"
}
