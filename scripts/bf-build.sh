#!/usr/bin/env bash
# scripts/bf-build.sh — build the botwork-base image with botforge build
# (SSH-provisioned, booted-KVM model).
#
# This script is TRANSITIONAL.  Two responsibilities still live here that
# will migrate into botforge/config one-by-one.  Each section is labelled so
# it can be deleted as the corresponding capability lands in botforge:
#
#   MIGRATION 1 — upstream Debian fetch + checksum-verify
#     DONE: now resolved by botforge via `image: @debian-base` in
#     build.yaml + `--config shasset.yaml` (shasset fetches/verifies/caches
#     the sha256-pinned Debian qcow2 under build/cache/).
#
#   MIGRATION 2 — compression + backing-file assertion
#     Becomes a `compress:` / output declaration in build.yaml; botforge
#     emits the compressed qcow2 directly.  When that lands, delete the
#     MIGRATION 2 block below (qemu-img convert + no-backing-file check).
#
#   MIGRATION 3 — CLI wiring (--repo-root / --spec / --config / --output)
#     Collapses to `botforge build <config>` once the config names its own
#     source, output, and compression.  When that lands (after MIGRATION 2
#     is complete), the `run_botforge_compose` invocation shrinks to:
#       run_botforge_compose image-build -- build \
#         "${REPO_ROOT}/images/botwork-base/build.yaml"
#     At that point this entire script can be deleted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/tools.sh
source "${SCRIPT_DIR}/lib/tools.sh"

usage() {
  cat <<USAGE
Usage: $0 [--compress|--no-compress] [-h|--help]
  Builds botwork-base using botforge build (SSH-provisioned, booted KVM).
  The upstream Debian cloud qcow2 is fetched, verified (sha256-pinned), and
  cached under build/cache/ by botforge via the shasset debian-base asset.
  Default is --no-compress.
USAGE
}

NO_COMPRESS=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compress)
      NO_COMPRESS=false
      shift
      ;;
    --no-compress)
      NO_COMPRESS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown argument: $1"
      ;;
    *)
      die "unexpected argument: $1 (bf-build.sh builds botwork-base only; no image-name argument)"
      ;;
  esac
done

ensure_command docker

STAGED_DIR="${BUILD_DIR}/images"
mkdir -p "${STAGED_DIR}"
BASE_OUTPUT="${STAGED_DIR}/botwork-base.qcow2"

# ─── MIGRATION 3: CLI wiring ──────────────────────────────────────────────────
# When botforge build derives source/output from build.yaml, delete the
# explicit flags.  The invocation then collapses to:
#   run_botforge_compose image-build -- build \
#     "${REPO_ROOT}/images/botwork-base/build.yaml"
log_info "Building botwork-base from spec ${REPO_ROOT}/images/botwork-base/build.yaml → ${BASE_OUTPUT}"
run_botforge_compose image-build -- \
  build \
  --repo-root "${REPO_ROOT}" \
  --spec "${REPO_ROOT}/images/botwork-base/build.yaml" \
  --config "${REPO_ROOT}/shasset.yaml" \
  --cache-dir "${BUILD_DIR}/cache" \
  --output "${BASE_OUTPUT}"
# ─────────────────────────────────────────────────────────────────────────────

# ─── MIGRATION 2: compression + backing-file assertion ────────────────────────
# When botforge build supports a `compress:` output declaration in build.yaml,
# delete this block and declare compression in
# images/botwork-base/build.yaml instead.
if [[ "${NO_COMPRESS}" == "false" ]]; then
  compressed="${BUILD_DIR}/botwork-base-compressed.qcow2"
  log_info "Compressing qcow2 → ${compressed}"
  # Compress under the image-build compose service: the botforge image
  # already bakes qemu-utils for the libguestfs appliance, so reusing it
  # keeps the host requirement at "docker only". --entrypoint qemu-img
  # bypasses the botforge CLI for one raw call. ${BUILD_DIR} is bind-
  # mounted at the same path inside the container via compose.yml, so
  # in-container paths match host paths.
  run_botforge_compose --entrypoint qemu-img image-build -- \
    convert -O qcow2 -c "${BASE_OUTPUT}" "${compressed}.partial"
  mv "${compressed}.partial" "${compressed}"
  info_output="$(run_botforge_compose --entrypoint qemu-img image-build -- info "${compressed}")"
  if grep -q '^backing file:' <<< "${info_output}"; then
    die "compressed qcow2 unexpectedly has a backing file: ${compressed}"
  fi
fi
# ─────────────────────────────────────────────────────────────────────────────

log_info "Build complete"
