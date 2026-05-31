#!/usr/bin/env bash
# scripts/lib/tools.sh — helpers for the botworkz/botwork sibling checkout.
# Source this file (after common.sh sets REPO_ROOT) to get:
#   BOTWORK_TOOLS_DIR       – path to the sibling checkout (workspace root)
#   ensure_tools_sibling()   – die if sibling is missing/incomplete
#   build_tools_launcher()   – `cargo build --release --locked -p botwork-launcher`
#   build_tools_cli()        – `cargo build --release --locked -p botwork-tools`
set -euo pipefail

BOTWORK_TOOLS_DIR="$(realpath -m "${BOTWORK_TOOLS_DIR:-${REPO_ROOT}/../botwork}")"

ensure_tools_sibling() {
  if [[ ! -f "${BOTWORK_TOOLS_DIR}/Cargo.toml" ]]; then
    die "botworkz/botwork sibling not found or incomplete at ${BOTWORK_TOOLS_DIR} (missing Cargo.toml workspace root). " \
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
  ensure_command curl

  local version base_url
  version="${BOTWORK_TOOLS_IMAGES_VERSION:-latest}"

  if [[ "${version}" == "latest" ]]; then
    base_url="https://github.com/botworkz/botwork/releases/latest/download"
  else
    base_url="https://github.com/botworkz/botwork/releases/download/v${version}"
  fi

  log_info "Downloading botwork-launcher from ${base_url} …"
  curl -fSL -o "${BUILD_DIR}/bin/botwork-launcher" "${base_url}/botwork-launcher"
  chmod +x "${BUILD_DIR}/bin/botwork-launcher"

  log_info "Downloading botwork-tools from ${base_url} …"
  curl -fSL -o "${BUILD_DIR}/bin/botwork-tools" "${base_url}/botwork-tools"
  chmod +x "${BUILD_DIR}/bin/botwork-tools"
}
