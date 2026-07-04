#!/usr/bin/env bash
# host-listener-allowlist.sh — fail loudly on any non-loopback TCP
# listener that isn't ssh (22) or the ingress envoy (:8080).
#
# Why this is a shell script and not a goss `command:` check:
# goss collapses command stdout in failure reports to a Go type repr
# ("object: *bytes.Reader") so the actual diagnostic is impossible to
# read in CI. test-packed.yaml runs each step via SSH and streams
# stdout/stderr back to the runner log verbatim, which is exactly what
# we need for "tell me which port is bound".
set -euo pipefail

listeners="$(ss -tlnp 2>/dev/null || ss -tln)"

bad="$(printf '%s\n' "${listeners}" \
  | awk 'NR>1 {print $4}' \
  | grep -v '^127\.' \
  | grep -v '^\[::1\]' \
  | awk -F: '{print $NF}' \
  | sort -nu \
  | grep -vx '22' \
  | grep -vx '8080' \
  || true)"

if [ -n "${bad}" ]; then
  echo "FAIL host_tcp_listener_allowlist: unexpected non-loopback TCP listeners"
  echo
  echo "bad ports:"
  printf '  %s\n' "${bad}"
  echo
  echo "matching listener rows:"
  for p in ${bad}; do
    printf '%s\n' "${listeners}" | awk -v port=":${p}\$" '$4 ~ port'
  done
  echo
  echo "(full ss -tlnp output for context:)"
  printf '%s\n' "${listeners}"
  exit 1
fi

echo "OK host_tcp_listener_allowlist: only 22 and 8080 are on non-loopback"
