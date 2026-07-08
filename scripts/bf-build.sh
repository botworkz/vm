#!/usr/bin/env bash
# scripts/bf-build.sh — build the botwork-base image with botforge build
# (SSH-provisioned, booted-KVM model).
#
# This script is TRANSITIONAL.  Three responsibilities still live here that
# will migrate into botforge/config one-by-one.  Each section is labelled so
# it can be deleted as the corresponding capability lands in botforge:
#
#   MIGRATION 1 — upstream Debian fetch + checksum-verify
#     Becomes a `source: {url: …, sha512: …}` key in build.yaml; botforge
#     fetches and verifies the upstream image itself.  When that lands, delete
#     fetch_debian_cloud_image(), DEBIAN_IMAGE_BASE_URL, DEBIAN_IMAGE_FILE,
#     and the MIGRATION 1 call-site below.
#
#   MIGRATION 2 — compression + backing-file assertion
#     Becomes a `compress:` / output declaration in build.yaml; botforge
#     emits the compressed qcow2 directly.  When that lands, delete the
#     MIGRATION 2 block below (qemu-img convert + no-backing-file check).
#
#   MIGRATION 3 — CLI wiring (--repo-root / --spec / --source / --output)
#     Collapses to `botforge build <config>` once the config names its own
#     source, output, and compression.  When that lands (after MIGRATION 1
#     and 2 are complete), the `run_botforge_compose` invocation shrinks to:
#       run_botforge_compose image-build -- build \
#         "${REPO_ROOT}/images/botwork-base/build.yaml"
#     At that point this entire script can be deleted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/tools.sh
source "${SCRIPT_DIR}/lib/tools.sh"

# ─── MIGRATION 1: upstream Debian source ──────────────────────────────────────
# When botforge supports `source: {url: …, sha512: …}` in build.yaml, delete
# these two variable declarations and the fetch_debian_cloud_image() function
# (and its call-site below).
DEBIAN_IMAGE_BASE_URL="${DEBIAN_IMAGE_BASE_URL:-https://cloud.debian.org/images/cloud/trixie/latest}"
DEBIAN_IMAGE_FILE="${DEBIAN_IMAGE_FILE:-debian-13-genericcloud-amd64.qcow2}"
# ─────────────────────────────────────────────────────────────────────────────

usage() {
  cat <<USAGE
Usage: $0 [--compress|--no-compress] [-h|--help]
  Builds botwork-base using botforge build (SSH-provisioned, booted KVM).
  The upstream Debian cloud qcow2 is downloaded into build/cache/ and
  verified against its published SHA512SUMS entry.
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

# ─── MIGRATION 1: upstream Debian source ──────────────────────────────────────
# fetch_debian_cloud_image — download + verify the upstream qcow2 into
# build/cache/. Idempotent: skips download when the cached file already
# matches the published SHA512SUMS entry.
fetch_debian_cloud_image() {
  local cache_dir="${BUILD_DIR}/cache"
  local img_path="${cache_dir}/${DEBIAN_IMAGE_FILE}"
  local sums_path="${cache_dir}/SHA512SUMS"

  mkdir -p "${cache_dir}"
  ensure_command curl
  ensure_command sha512sum

  log_info "Refreshing ${DEBIAN_IMAGE_BASE_URL}/SHA512SUMS"
  curl -fsSL -o "${sums_path}.new" "${DEBIAN_IMAGE_BASE_URL}/SHA512SUMS"
  mv "${sums_path}.new" "${sums_path}"

  local expected_sum
  expected_sum="$(awk -v f="${DEBIAN_IMAGE_FILE}" '$2 == f { print $1 }' "${sums_path}")"
  [[ -n "${expected_sum}" ]] \
    || die "SHA512SUMS at ${DEBIAN_IMAGE_BASE_URL} has no entry for ${DEBIAN_IMAGE_FILE}"

  if [[ -f "${img_path}" ]]; then
    local have_sum
    have_sum="$(sha512sum "${img_path}" | awk '{print $1}')"
    if [[ "${have_sum}" == "${expected_sum}" ]]; then
      log_info "Reusing cached upstream image: ${img_path}"
      echo "${img_path}"
      return 0
    fi
    log_warn "Cached upstream image checksum mismatch, re-downloading"
    rm -f "${img_path}"
  fi

  log_info "Downloading ${DEBIAN_IMAGE_BASE_URL}/${DEBIAN_IMAGE_FILE}"
  curl -fsSL -o "${img_path}.partial" "${DEBIAN_IMAGE_BASE_URL}/${DEBIAN_IMAGE_FILE}"
  local got_sum
  got_sum="$(sha512sum "${img_path}.partial" | awk '{print $1}')"
  [[ "${got_sum}" == "${expected_sum}" ]] \
    || die "checksum mismatch for ${DEBIAN_IMAGE_FILE}: got ${got_sum}, expected ${expected_sum}"
  mv "${img_path}.partial" "${img_path}"
  echo "${img_path}"
}
# ─────────────────────────────────────────────────────────────────────────────

STAGED_DIR="${BUILD_DIR}/images"
mkdir -p "${STAGED_DIR}"
BASE_OUTPUT="${STAGED_DIR}/botwork-base.qcow2"

# ─── MIGRATION 1: upstream Debian source ──────────────────────────────────────
# Delete this line once build.yaml carries `source: {url: …, sha512: …}`.
source_image="$(fetch_debian_cloud_image)"
# ─────────────────────────────────────────────────────────────────────────────

# ─── MIGRATION 3: CLI wiring ──────────────────────────────────────────────────
# When botforge build derives source/output from build.yaml, delete the four
# explicit flags.  The invocation then collapses to:
#   run_botforge_compose image-build -- build \
#     "${REPO_ROOT}/images/botwork-base/build.yaml"
log_info "Building botwork-base from spec ${REPO_ROOT}/images/botwork-base/build.yaml → ${BASE_OUTPUT}"
run_botforge_compose image-build -- \
  build \
  --repo-root "${REPO_ROOT}" \
  --spec "${REPO_ROOT}/images/botwork-base/build.yaml" \
  --source "${source_image}" \
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
