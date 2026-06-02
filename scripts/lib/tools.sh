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
  ensure_command docker

  local shasset_pin_file shasset_image shasset_out
  shasset_pin_file="${REPO_ROOT}/deps/container/shasset.Dockerfile"
  [[ -f "${shasset_pin_file}" ]] || die "missing shasset image pin file: ${shasset_pin_file}"

  shasset_image="$(grep -m1 '^FROM[[:space:]]' "${shasset_pin_file}" | awk '{print $2}' || true)"
  [[ -n "${shasset_image}" ]] || die "invalid shasset image pin in ${shasset_pin_file}"

  mkdir -p "${BUILD_DIR}/bin"
  shasset_out="${BUILD_DIR}/bin/.shasset"
  rm -rf "${shasset_out}"
  mkdir -p "${shasset_out}"

  log_info "Fetching botwork binaries via shasset (${shasset_image}) …"
  docker run --rm \
    -v "${REPO_ROOT}/shasset.yaml:/work/shasset.yaml:ro" \
    -v "${shasset_out}:/out" \
    "${shasset_image}" \
    --config /work/shasset.yaml fetch --out /out

  [[ -f "${shasset_out}/botwork-launcher/botwork-launcher" ]] \
    || die "shasset output missing botwork-launcher at ${shasset_out}/botwork-launcher/botwork-launcher"
  [[ -f "${shasset_out}/botwork-tools/botwork-tools" ]] \
    || die "shasset output missing botwork-tools at ${shasset_out}/botwork-tools/botwork-tools"

  cp "${shasset_out}/botwork-launcher/botwork-launcher" "${BUILD_DIR}/bin/botwork-launcher"
  cp "${shasset_out}/botwork-tools/botwork-tools" "${BUILD_DIR}/bin/botwork-tools"
  chmod +x "${BUILD_DIR}/bin/botwork-launcher" "${BUILD_DIR}/bin/botwork-tools"
  rm -rf "${shasset_out}"
}
