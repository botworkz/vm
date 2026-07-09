#!/usr/bin/env bash
# scripts/pack.sh — build VM images with botforge, no Packer.
#
# Resolves the requested image's parent chain in images/manifest.yaml, then
# walks the chain root-first, invoking `botforge build` inside the botforge
# container for each level against images/<name>/build.yaml. The first image's
# source is the upstream Debian
# cloud qcow2 (downloaded + verified by this script and cached under
# build/cache/). Each subsequent image inherits its parent's build output.
#
# With --source <qcow2>, skip the parent-chain walk entirely and build only
# the named image on top of the provided source artifact.
#
# Optional --compress runs qemu-img convert -c on the final image only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/tools.sh
source "${SCRIPT_DIR}/lib/tools.sh"
# shellcheck source=scripts/lib/botworkz.sh
source "${SCRIPT_DIR}/lib/botworkz.sh"
# shellcheck source=scripts/lib/images.sh
source "${SCRIPT_DIR}/lib/images.sh"
# shellcheck source=scripts/lib/manifest.sh
source "${SCRIPT_DIR}/lib/manifest.sh"

# Upstream Debian cloud image. The qcow2 URL is downloaded into
# build/cache/ and verified against the matching SHA512SUMS entry from the
# same directory. To bump, point both at a different snapshot directory
# (e.g. trixie/20260108-1742 instead of trixie/latest).
DEBIAN_IMAGE_BASE_URL="${DEBIAN_IMAGE_BASE_URL:-https://cloud.debian.org/images/cloud/trixie/latest}"
DEBIAN_IMAGE_FILE="${DEBIAN_IMAGE_FILE:-debian-13-genericcloud-amd64.qcow2}"

usage() {
  cat <<USAGE
Usage: $0 [--compress|--no-compress] [--source <qcow2>] [image-name] [-h|--help]
  Default is --no-compress unless --source is set, in which case the default
  is --compress. Image builds run inside the botforge container via the
  'image-build' compose service. Without --source, each link in the parent
  DAG is built by invoking 'botforge build' against images/<name>/build.yaml.
  With --source, only the named image is built on top of the supplied qcow2.
USAGE
}

NO_COMPRESS=true
COMPRESS_MODE_SET=false
IMAGE_NAME="botwork"
IMAGE_NAME_SET=false
SOURCE_IMAGE=""
MANIFEST_PATH="${REPO_ROOT}/images/manifest.yaml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compress)
      NO_COMPRESS=false
      COMPRESS_MODE_SET=true
      shift
      ;;
    --no-compress)
      NO_COMPRESS=true
      COMPRESS_MODE_SET=true
      shift
      ;;
    --source)
      SOURCE_IMAGE="${2:-}"
      [[ -n "${SOURCE_IMAGE}" ]] || die "--source requires a qcow2 path"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      die "unknown argument: $1"
      ;;
    *)
      if [[ "${IMAGE_NAME_SET}" == "true" ]]; then
        die "only one image-name positional argument is supported"
      fi
      IMAGE_NAME="$1"
      IMAGE_NAME_SET=true
      shift
      ;;
  esac
done

manifest_has "${IMAGE_NAME}" \
  || die "unknown image '${IMAGE_NAME}' (not found under images: in ${MANIFEST_PATH})"
IMAGE_TEMPLATE="images/${IMAGE_NAME}"
if [[ ! -d "${REPO_ROOT}/${IMAGE_TEMPLATE}" ]]; then
  die "image template directory not found: ${REPO_ROOT}/${IMAGE_TEMPLATE}"
fi
if [[ -n "${SOURCE_IMAGE}" ]]; then
  [[ -f "${SOURCE_IMAGE}" ]] || die "source qcow2 not found: ${SOURCE_IMAGE}"
  SOURCE_IMAGE="$(realpath "${SOURCE_IMAGE}")"
  if [[ "${COMPRESS_MODE_SET}" == "false" ]]; then
    NO_COMPRESS=false
  fi
fi

ensure_command docker

if [[ -n "${BOTWORK_SSH_PUBLIC_KEY:-}" ]]; then
  log_info "BOTWORK_SSH_PUBLIC_KEY is only used at deploy time and will be ignored during the build process."
fi

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

# image_needs_staged_dependencies <name>
# Returns 0 when the image's build spec references staged botwork payload
# artifacts under build/bin, build/images/baked, or the botwork context tar.
image_needs_staged_dependencies() {
  local name="$1"
  local spec="${REPO_ROOT}/images/${name}/build.yaml"
  [[ -f "${spec}" ]] || die "build spec not found: ${spec}"
  grep -Eq 'build/(bin|images/baked|botwork-build-context(\.tar)?)' "${spec}"
}

# build_image <name> <src-qcow2> <out-qcow2>
# Drives `botforge build` against images/<name>/build.yaml inside the
# image-build compose service.
build_image() {
  local name="$1" src="$2" out="$3"
  local spec="${REPO_ROOT}/images/${name}/build.yaml"
  [[ -f "${spec}" ]] || die "build spec not found: ${spec}"

  log_info "Building image '${name}' from spec ${spec} → ${out}"
  run_botforge_compose image-build -- \
    build \
    --repo-root "${REPO_ROOT}" \
    --spec "${spec}" \
    --config "${REPO_ROOT}/shasset.yaml" \
    --cache-dir "${BUILD_DIR}/cache" \
    --source "${src}" \
    --output "${out}"
}

STAGED_DIR="${BUILD_DIR}/images"
mkdir -p "${STAGED_DIR}"

if image_needs_staged_dependencies "${IMAGE_NAME}"; then
  log_info "Building and staging dependencies/helpers …"
  "${SCRIPT_DIR}/build-deps.sh"
fi

initial_source=""
if [[ -n "${SOURCE_IMAGE}" ]]; then
  initial_source="${SOURCE_IMAGE}"
  CHAIN=("${IMAGE_NAME}")
else
  initial_source="$(fetch_debian_cloud_image)"

  # Resolve the parent chain (root first) and walk it. Each link's source is
  # either the upstream Debian image (for the root) or the previous link's
  # output. Cached intermediates are reused.
  read -r -a CHAIN <<< "$(manifest_chain "${IMAGE_NAME}")"
fi

prev_output=""
final_output=""
for name in "${CHAIN[@]}"; do
  out_name="$(manifest_output "${name}")"
  staged="${STAGED_DIR}/${out_name}"

  if [[ -z "${prev_output}" ]]; then
    src="${initial_source}"
  else
    src="${prev_output}"
  fi

  if [[ -f "${staged}" && "${name}" != "${IMAGE_NAME}" ]]; then
    log_info "Reusing cached intermediate image: ${staged}"
  else
    build_image "${name}" "${src}" "${staged}"
  fi
  prev_output="${staged}"
  final_output="${staged}"
done

if [[ "${NO_COMPRESS}" == "false" ]]; then
  out_name="$(manifest_output "${IMAGE_NAME}")"
  out_stem="${out_name%.qcow2}"
  compressed="${BUILD_DIR}/${out_stem}-compressed.qcow2"
  log_info "Compressing qcow2 → ${compressed}"
  # Compress under the image-build compose service: the botforge image
  # already bakes qemu-utils for the libguestfs appliance, so reusing it
  # keeps the host requirement at "docker only". --entrypoint qemu-img
  # bypasses the botforge CLI for one raw call. ${BUILD_DIR} is bind-
  # mounted at the same path inside the container via compose.yml, so
  # in-container paths match host paths.
  run_botforge_compose --entrypoint qemu-img image-build -- \
    convert -O qcow2 -c "${final_output}" "${compressed}.partial"
  mv "${compressed}.partial" "${compressed}"
  info_output="$(run_botforge_compose --entrypoint qemu-img image-build -- info "${compressed}")"
  if grep -q '^backing file:' <<< "${info_output}"; then
    die "compressed qcow2 unexpectedly has a backing file: ${compressed}"
  fi
fi

log_info "Pack complete"
