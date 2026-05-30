#!/usr/bin/env bash
# scripts/lib/botwork.sh — helpers for the botwork-mcp sibling checkout.
#
# Source this file (after common.sh sets REPO_ROOT) to get:
#   BOTWORK_MCP_DIR          – path to the sibling checkout
#   botwork_containers_dir() – ${BOTWORK_MCP_DIR}/containers
#   botwork_dist_dir()       – ${BOTWORK_MCP_DIR}/containers/dist
#   ensure_botwork_sibling() – die if sibling is missing/incomplete
set -euo pipefail

if [[ "${_BOTWORK_BOTWORK_LIB_SOURCED:-0}" == "1" ]]; then
  return 0
fi
_BOTWORK_BOTWORK_LIB_SOURCED=1

BOTWORK_MCP_DIR="$(realpath -m "${BOTWORK_MCP_DIR:-${REPO_ROOT}/../botwork-mcp}")"

botwork_containers_dir() { echo "${BOTWORK_MCP_DIR}/containers"; }
botwork_dist_dir()        { echo "${BOTWORK_MCP_DIR}/containers/dist"; }

ensure_botwork_sibling() {
  if [[ ! -f "${BOTWORK_MCP_DIR}/Makefile" ]]; then
    die "botwork-mcp sibling not found or incomplete at ${BOTWORK_MCP_DIR} (missing Makefile). " \
      "Clone phlax/botwork-mcp next to this repo or set BOTWORK_MCP_DIR."
  fi
  if [[ ! -f "${BOTWORK_MCP_DIR}/containers/Makefile" ]]; then
    die "botwork-mcp sibling not found or incomplete at ${BOTWORK_MCP_DIR} (missing containers/Makefile). " \
      "Clone phlax/botwork-mcp next to this repo or set BOTWORK_MCP_DIR."
  fi
}
