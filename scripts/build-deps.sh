#!/usr/bin/env bash
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

mkdir -p "${BUILD_DIR}/bin"
mkdir -p "${BUILD_DIR}/images/baked"

if [[ "$(images_mode)" == "sibling" ]]; then
  ensure_tools_sibling
  build_tools_launcher
  build_tools_cli

  cp "${BOTWORK_TOOLS_DIR}/target/release/botwork-launcher" "${BUILD_DIR}/bin/"
  cp "${BOTWORK_TOOLS_DIR}/target/release/botwork-tools" "${BUILD_DIR}/bin/"
else
  fetch_tools_binaries
fi

[[ "$(botworkz_images_mode)" == "sibling" ]] && ensure_botworkz_sibling

ensure_images

# botwork context tarball consumed by images/botwork/build.yaml. Keep the output
# path centralized here; build/ layout may be reorganized later.
BOTWORK_BUILD_CONTEXT_TAR="${BUILD_DIR}/botwork-build-context.tar"
BOTWORK_BUILD_CONTEXT_STAGE_DIR="$(mktemp -d)"
cleanup_botwork_build_context_stage() {
  rm -rf "${BOTWORK_BUILD_CONTEXT_STAGE_DIR}"
}
trap cleanup_botwork_build_context_stage EXIT

for src in \
  "${REPO_ROOT}/images/botwork/payload/envoy" \
  "${REPO_ROOT}/images/botwork/payload/systemd" \
  "${REPO_ROOT}/images/botwork/payload/firstboot" \
  "${BUILD_DIR}/bin" \
  "${BUILD_DIR}/images/baked"
do
  [[ -d "${src}" ]] || die "missing required botwork context source directory: ${src}"
done

mkdir -p \
  "${BOTWORK_BUILD_CONTEXT_STAGE_DIR}/envoy" \
  "${BOTWORK_BUILD_CONTEXT_STAGE_DIR}/systemd" \
  "${BOTWORK_BUILD_CONTEXT_STAGE_DIR}/firstboot" \
  "${BOTWORK_BUILD_CONTEXT_STAGE_DIR}/bin" \
  "${BOTWORK_BUILD_CONTEXT_STAGE_DIR}/images"

cp -a "${REPO_ROOT}/images/botwork/payload/envoy/." "${BOTWORK_BUILD_CONTEXT_STAGE_DIR}/envoy/"
cp -a "${REPO_ROOT}/images/botwork/payload/systemd/." "${BOTWORK_BUILD_CONTEXT_STAGE_DIR}/systemd/"
cp -a "${REPO_ROOT}/images/botwork/payload/firstboot/." "${BOTWORK_BUILD_CONTEXT_STAGE_DIR}/firstboot/"
cp -a "${BUILD_DIR}/bin/." "${BOTWORK_BUILD_CONTEXT_STAGE_DIR}/bin/"
cp -a "${BUILD_DIR}/images/baked/." "${BOTWORK_BUILD_CONTEXT_STAGE_DIR}/images/"

rm -f "${BOTWORK_BUILD_CONTEXT_TAR}"
tar -C "${BOTWORK_BUILD_CONTEXT_STAGE_DIR}" \
  -cf "${BOTWORK_BUILD_CONTEXT_TAR}" \
  envoy \
  systemd \
  firstboot \
  bin \
  images
