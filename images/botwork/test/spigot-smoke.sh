#!/usr/bin/env bash
# spigot-smoke.sh — end-to-end test for the frontdoor spigot flip.
#
# Sequence
# --------
#   1. Verify default: GET http://127.0.0.1/ returns the holding page
#      (served via Envoy direct_response — no upstream required).
#   2. Flip spigot open: atomically swap rds/active.yaml to route to
#      the ingress cluster.
#   3. Poll until Envoy reloads and the response is no longer the holding
#      page (proving the IN_MOVED_TO inotify event fired and the new RDS
#      config was parsed).
#   4. Assert response does NOT contain the holding-page marker.
#   5. Flip spigot closed: atomically restore the direct_response config.
#   6. Poll until the holding page is back.
#   7. Assert holding-page marker is present again.
#
# The EXIT trap ensures rds/active.yaml is always restored to the original
# state even when an assertion fails mid-test. This is important because
# a stuck-open spigot would break any subsequent goss run that checks the
# holding page.
set -euo pipefail

if [[ -t 2 ]]; then
  COLOR_RED='\033[31m'
  COLOR_GREEN='\033[32m'
  COLOR_RESET='\033[0m'
else
  COLOR_RED=''
  COLOR_GREEN=''
  COLOR_RESET=''
fi

log_info()  { echo -e "${COLOR_GREEN}==>${COLOR_RESET} [spigot-smoke] $*" >&2; }
log_error() { echo -e "${COLOR_RED}ERROR:${COLOR_RESET} [spigot-smoke] $*" >&2; }
die()       { log_error "$*"; exit 1; }

RDS_DIR="/etc/botwork/envoy/frontdoor/rds"
RDS_ACTIVE="${RDS_DIR}/active.yaml"
RDS_BACKUP="${RDS_DIR}/active.yaml.spigot-smoke-backup"

HOLDING_MARKER="frontdoor: hello world"
POLL_ATTEMPTS="${SPIGOT_SMOKE_POLL_ATTEMPTS:-30}"

# ── RDS configs ───────────────────────────────────────────────────────────────
# direct_response: holding page (default/restore target)
HOLDING_RDS='resources:
- "@type": type.googleapis.com/envoy.config.route.v3.RouteConfiguration
  name: frontdoor_routes
  virtual_hosts:
  - name: frontdoor
    domains: ["*"]
    routes:
    - match:
        prefix: "/"
      response_headers_to_add:
      - header:
          key: content-type
          value: "text/html; charset=utf-8"
        keep_empty_value: false
      direct_response:
        status: 200
        body:
          inline_string: |
            <!doctype html><meta charset=utf-8>
            <title>botwork frontdoor</title>
            <h1>frontdoor: hello world</h1>
            <p>Base holding content. Override by swapping rds/active.yaml.</p>'

# cluster route: open to ingress (spigot-on state)
INGRESS_RDS='resources:
- "@type": type.googleapis.com/envoy.config.route.v3.RouteConfiguration
  name: frontdoor_routes
  virtual_hosts:
  - name: frontdoor
    domains: ["*"]
    routes:
    - match:
        prefix: "/"
      route:
        cluster: ingress'

# ── Helpers ───────────────────────────────────────────────────────────────────

# Atomic RDS write: write to .new on the same filesystem then mv → active
# (triggers IN_MOVED_TO, the only inotify event Envoy FS-xDS watches for).
write_rds() {
  local content="$1"
  printf '%s\n' "${content}" > "${RDS_ACTIVE}.new"
  mv "${RDS_ACTIVE}.new" "${RDS_ACTIVE}"
}

# Restore original active.yaml from backup on failure.
# On success the backup is removed before exit so this is a no-op.
cleanup() {
  if [ -f "${RDS_BACKUP}" ]; then
    mv "${RDS_BACKUP}" "${RDS_ACTIVE}"
    log_error "restored RDS from backup (script did not complete cleanly)"
  fi
}
trap cleanup EXIT

# Poll http://127.0.0.1/ until the body matches or stops matching the holding
# page marker. Returns 0 when the expected state is reached, 1 on timeout.
#   poll_frontdoor <expect_holding: true|false>
poll_frontdoor() {
  local expect_holding="$1"
  local i=0 body
  while [ "$i" -lt "${POLL_ATTEMPTS}" ]; do
    body="$(curl -sS --max-time 5 http://127.0.0.1/ 2>/dev/null || true)"
    if [ "${expect_holding}" = "true" ]; then
      printf '%s' "${body}" | grep -q "${HOLDING_MARKER}" && return 0
    else
      ! printf '%s' "${body}" | grep -q "${HOLDING_MARKER}" \
        && [ -n "${body}" ] \
        && return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# ── Steps ─────────────────────────────────────────────────────────────────────

# 1. Verify default: holding page
log_info "step 1: verify default state is holding page"
poll_frontdoor true \
  || { curl -v http://127.0.0.1/ >&2 || true
       die "default: holding page not served after ${POLL_ATTEMPTS}s"; }
log_info "step 1 OK — holding page served by default"

# Save the original RDS before modifying it
cp "${RDS_ACTIVE}" "${RDS_BACKUP}"

# 2. Flip spigot open (direct_response → cluster: ingress)
log_info "step 2: flipping spigot open (writing ingress RDS)"
write_rds "${INGRESS_RDS}"

# 3. Poll until holding page is gone (Envoy reloaded RDS)
log_info "step 3: waiting for Envoy to reload — expecting non-holding response"
poll_frontdoor false \
  || { curl -v http://127.0.0.1/ >&2 || true
       die "spigot open: still serving holding page after ${POLL_ATTEMPTS}s (Envoy did not reload)"; }
log_info "step 3 OK — Envoy reloaded, non-holding response received"

# 4. Confirm not-holding
body="$(curl -sS --max-time 5 http://127.0.0.1/ 2>/dev/null || true)"
if printf '%s' "${body}" | grep -q "${HOLDING_MARKER}"; then
  die "spigot open: response still contains holding marker after confirmed reload"
fi
log_info "step 4 OK — confirmed not-holding (spigot is open)"

# 5. Flip spigot closed (cluster: ingress → direct_response)
log_info "step 5: flipping spigot closed (restoring holding RDS)"
write_rds "${HOLDING_RDS}"

# 6. Poll until holding page is back
log_info "step 6: waiting for Envoy to reload — expecting holding page"
poll_frontdoor true \
  || { curl -v http://127.0.0.1/ >&2 || true
       die "spigot closed: holding page not served after ${POLL_ATTEMPTS}s (Envoy did not reload)"; }
log_info "step 6 OK — holding page is back"

# 7. Confirm holding page is back
body="$(curl -sS --max-time 5 http://127.0.0.1/ 2>/dev/null || true)"
printf '%s' "${body}" | grep -q "${HOLDING_MARKER}" \
  || die "spigot closed: response does not contain holding marker"
log_info "step 7 OK — confirmed holding page restored"

# Remove backup so the EXIT trap is a no-op (clean exit path)
rm -f "${RDS_BACKUP}"

log_info "ALL STEPS PASSED"
