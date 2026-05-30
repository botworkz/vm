#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=scripts/lib/tools.sh
source "${SCRIPT_DIR}/lib/tools.sh"
# shellcheck source=scripts/lib/botwork.sh
source "${SCRIPT_DIR}/lib/botwork.sh"
# shellcheck source=scripts/lib/botworkz.sh
source "${SCRIPT_DIR}/lib/botworkz.sh"
# shellcheck source=scripts/lib/images.sh
source "${SCRIPT_DIR}/lib/images.sh"

ensure_tools_sibling
[[ "$(botwork_images_mode)" == "sibling" ]] && ensure_botwork_sibling
[[ "$(botworkz_images_mode)" == "sibling" ]] && ensure_botworkz_sibling
build_tools_launcher
build_tools_cli

mkdir -p "${BUILD_DIR}/bin"
cp "${BOTWORK_TOOLS_DIR}/target/release/botwork-launcher" "${BUILD_DIR}/bin/"
cp "${BOTWORK_TOOLS_DIR}/target/release/botwork-tools" "${BUILD_DIR}/bin/"

ensure_images
