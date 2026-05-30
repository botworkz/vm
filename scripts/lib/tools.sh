#!/usr/bin/env bash
# scripts/lib/tools.sh — helpers for the botspace-tools sibling checkout.
# Runtime/image namespaces migrated to botwork, but the sibling repo path remains
# ../botspace-tools because the repository itself is not renamed.
#
# Source this file (after common.sh sets REPO_ROOT) to get:
#   BOTWORK_TOOLS_DIR       – path to the sibling checkout (workspace root)
#   ensure_tools_sibling()   – die if sibling is missing/incomplete
#   build_tools_launcher()   – `cargo build --release --locked -p botwork-launcher`
#   build_tools_cli()        – `cargo build --release --locked -p botwork-tools`
set -euo pipefail

BOTWORK_TOOLS_DIR="$(realpath -m "${BOTWORK_TOOLS_DIR:-${REPO_ROOT}/../botspace-tools}")"

ensure_tools_sibling() {
  if [[ ! -f "${BOTWORK_TOOLS_DIR}/Cargo.toml" ]]; then
    die "botspace-tools sibling not found or incomplete at ${BOTWORK_TOOLS_DIR} (missing Cargo.toml workspace root). " \
      "Clone phlax/botspace-tools next to this repo or set BOTWORK_TOOLS_DIR."
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
