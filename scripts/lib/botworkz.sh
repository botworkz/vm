#!/usr/bin/env bash
# scripts/lib/botworkz.sh — helpers for the botworkz/mcp sibling checkout.
set -euo pipefail

if [[ "${_BOTSPACE_BOTWORKZ_LIB_SOURCED:-0}" == "1" ]]; then
  return 0
fi
_BOTSPACE_BOTWORKZ_LIB_SOURCED=1

BOTWORKZ_MCP_DIR="$(realpath -m "${BOTWORKZ_MCP_DIR:-${REPO_ROOT}/../mcp}")"

ensure_botworkz_sibling() {
  if [[ ! -f "${BOTWORKZ_MCP_DIR}/Earthfile" ]]; then
    die "botworkz/mcp sibling not found or incomplete at ${BOTWORKZ_MCP_DIR} (missing Earthfile). Clone https://github.com/botworkz/mcp next to this repo or set BOTWORKZ_MCP_DIR."
  fi
}
