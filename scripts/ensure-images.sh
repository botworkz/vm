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

usage() {
  cat <<USAGE
Usage: $0 [--mode sibling|registry] [--version <tag>] [-h|--help]

Modes:
  registry  Pull all images from published GHCR tags (default).
  sibling   Build botwork/session-broker and botwork/mcp-echo from sibling repos,
            and also build botwork/packer-tools from sibling botworkz/tools.

Env overrides:
  BOTWORK_TOOLS_IMAGES_REF     session-broker source (empty=>registry|sibling|registry|ghcr.io/...)
  BOTWORKZ_MCP_IMAGES_REF      mcp-echo source (empty=>registry|sibling|registry|ghcr.io/...)
  BOTWORK_PACKER_TOOLS_REF     packer-tools source (empty=>registry|registry|sibling|ghcr.io/...)

Sibling mode requires EarthBuild installed as the 'earthly' command.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      case "${2:-}" in
        sibling)
          BOTWORK_TOOLS_IMAGES_REF="sibling"
          BOTWORKZ_MCP_IMAGES_REF="sibling"
          BOTWORK_PACKER_TOOLS_REF="sibling"
          ;;
        registry)
          BOTWORK_TOOLS_IMAGES_REF="registry"
          BOTWORKZ_MCP_IMAGES_REF="registry"
          BOTWORK_PACKER_TOOLS_REF="registry"
          ;;
        *) die "invalid --mode: ${2:-} (expected sibling|registry)" ;;
      esac
      shift 2
      ;;
    --version)
      BOTWORK_TOOLS_IMAGES_VERSION="${2:-}"
      [[ -n "${BOTWORK_TOOLS_IMAGES_VERSION}" ]] || die "--version requires a value"
      BOTWORKZ_MCP_IMAGES_VERSION="${BOTWORK_TOOLS_IMAGES_VERSION}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

ensure_images
