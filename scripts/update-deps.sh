#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ensure_command curl
ensure_command sha256sum
ensure_command awk

LOCK_FILE="${REPO_ROOT}/deps.lock"
[[ -f "${LOCK_FILE}" ]] || die "missing deps lock file: ${LOCK_FILE}"

# Image digest pins are intentionally not managed by this script.
# Keep deps/container/*.Dockerfile FROM ...@sha256:<digest> anchors in sync by hand
# (or by digest resolution tooling) whenever a *_VERSION_LOCK is bumped.

update_lock_key() {
  local key="$1"
  local value="$2"
  local tmp_file

  tmp_file="$(mktemp)"
  awk -v key="${key}" -v value="${value}" '
    BEGIN { updated = 0 }
    $0 ~ ("^" key "=") { print key "=" value; updated = 1; next }
    { print }
    END { if (!updated) print key "=" value }
  ' "${LOCK_FILE}" > "${tmp_file}"
  mv "${tmp_file}" "${LOCK_FILE}"
}

download_release_asset() {
  local owner="$1"
  local repo="$2"
  local tag="$3"
  local asset_name="$4"
  local output_path="$5"
  local token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  local asset_id release_api

  if [[ -n "${token}" ]]; then
    ensure_command jq
    release_api="https://api.github.com/repos/${owner}/${repo}/releases/tags/${tag}"
    asset_id="$(
      curl -fsSL \
        -H "$(printf 'Authorization: %s %s' 'Bearer' "${token}")" \
        -H "Accept: application/vnd.github+json" \
        "${release_api}" \
        | jq -r --arg name "${asset_name}" '.assets[]? | select(.name == $name) | .id' \
        | head -n1
    )"
    if [[ -n "${asset_id}" && "${asset_id}" != "null" ]]; then
      curl -fsSL \
        -L \
        -H "$(printf 'Authorization: %s %s' 'Bearer' "${token}")" \
        -H "Accept: application/octet-stream" \
        "https://api.github.com/repos/${owner}/${repo}/releases/assets/${asset_id}" \
        -o "${output_path}"
      return 0
    fi
    log_warn "Could not resolve asset id for ${asset_name} in ${owner}/${repo}@${tag}; falling back to anonymous download."
  fi

  curl -fsSL -o "${output_path}" "https://github.com/${owner}/${repo}/releases/download/${tag}/${asset_name}"
}

refresh_binary_pin() {
  local lock_key="$1"
  local owner="$2"
  local repo="$3"
  local tag="$4"
  local asset_name="$5"
  local tmp_file sha

  tmp_file="$(mktemp)"
  log_info "Refreshing ${lock_key} from ${owner}/${repo} ${tag} (${asset_name}) …"
  download_release_asset "${owner}" "${repo}" "${tag}" "${asset_name}" "${tmp_file}"
  sha="$(sha256sum "${tmp_file}" | awk '{print $1}')"
  rm -f "${tmp_file}"
  update_lock_key "${lock_key}" "${sha}"
  log_info "Updated ${lock_key}=${sha}"
}

BOTWORK_TAG="v${BOTWORK_TOOLS_VERSION_LOCK:-}"
[[ "${BOTWORK_TAG}" != "v" ]] || die "BOTWORK_TOOLS_VERSION_LOCK is empty in deps.lock"

refresh_binary_pin "BOTWORK_TOOLS_SHA256_botwork_launcher" "botworkz" "botwork" "${BOTWORK_TAG}" "botwork-launcher"
refresh_binary_pin "BOTWORK_TOOLS_SHA256_botwork_tools" "botworkz" "botwork" "${BOTWORK_TAG}" "botwork-tools"

log_info "Dependency lock update complete."
