#!/usr/bin/env bash
set -euo pipefail

if [[ "${_BOTWORK_MANIFEST_LIB_SOURCED:-0}" == "1" ]]; then
  return 0
fi
_BOTWORK_MANIFEST_LIB_SOURCED=1

manifest_file() {
  echo "${REPO_ROOT}/images/manifest.yaml"
}

manifest_has() {
  local image="$1"
  local file
  file="$(manifest_file)"
  [[ -f "${file}" ]] || die "images manifest not found: ${file}"
  awk -v image="${image}" '
    /^images:[[:space:]]*$/ { in_images=1; next }
    in_images && /^  [A-Za-z0-9._-]+:[[:space:]]*$/ {
      name=$1
      sub(/:$/, "", name)
      if (name == image) found=1
    }
    END { exit found ? 0 : 1 }
  ' "${file}"
}

_manifest_field() {
  local image="$1"
  local field="$2"
  local file
  file="$(manifest_file)"

  awk -v image="${image}" -v field="${field}" '
    /^images:[[:space:]]*$/ { in_images=1; next }
    in_images && /^  [A-Za-z0-9._-]+:[[:space:]]*$/ {
      current=$1
      sub(/:$/, "", current)
      in_target=(current == image)
      if (in_target) found=1
      next
    }
    in_target && $0 ~ ("^    " field ":[[:space:]]*") {
      value=$0
      sub("^    " field ":[[:space:]]*", "", value)
      print value
      got=1
      exit 0
    }
    END {
      if (!found) exit 2
      if (!got) exit 3
    }
  ' "${file}"
}

manifest_parent() {
  local image="$1"
  local parent
  if ! parent="$(_manifest_field "${image}" "parent")"; then
    case "$?" in
      2) die "unknown image '${image}' in $(manifest_file)" ;;
      3) die "missing parent for image '${image}' in $(manifest_file)" ;;
      *) die "failed reading parent for image '${image}' in $(manifest_file)" ;;
    esac
  fi
  echo "${parent}"
}

manifest_output() {
  local image="$1"
  local output
  if ! output="$(_manifest_field "${image}" "output")"; then
    case "$?" in
      2) die "unknown image '${image}' in $(manifest_file)" ;;
      3) die "missing output for image '${image}' in $(manifest_file)" ;;
      *) die "failed reading output for image '${image}' in $(manifest_file)" ;;
    esac
  fi
  echo "${output}"
}

manifest_chain() {
  local image="$1"
  local cursor="$image"
  local parent
  local -a path=()
  local -a chain=()
  local i
  declare -A seen=()

  while true; do
    if [[ -n "${seen["${cursor}"]+x}" ]]; then
      die "cycle detected in images manifest at '${cursor}'"
    fi
    seen["${cursor}"]=1
    path+=("${cursor}")
    parent="$(manifest_parent "${cursor}")"
    [[ "${parent}" == "null" ]] && break
    cursor="${parent}"
  done

  for (( i=${#path[@]}-1; i>=0; i-- )); do
    chain+=("${path[i]}")
  done

  echo "${chain[*]}"
}
