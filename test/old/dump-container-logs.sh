#!/usr/bin/env bash
# dump-container-logs.sh — best-effort dump of core botwork container
# state/logs for smoke-test failures.
#
# Why this is a shell script and not a goss `command:` probe:
# goss only surfaces command stderr/stdout when the probe itself fails,
# but the failures we care about are often downstream service checks
# that never get far enough to print the api/db-migrate/container-side
# logs. test-packed.yaml runs each step over SSH and streams its output
# verbatim into CI, so calling this from the base-goss failure path gets
# the container logs into the workflow log on the first failure.
set -u

containers=(
  botwork-api
  botwork-db-migrate
  botwork-config-broker
  botwork-session-broker
  botwork-control-plane
  botwork-envoy
  botwork-postgres
  botwork-import
)

echo "=== docker ps -a ==="
/usr/bin/docker ps -a || true

for container in "${containers[@]}"; do
  echo
  echo "=== docker inspect state: ${container} ==="
  /usr/bin/docker inspect "${container}" \
    --format 'status={{.State.Status}} exit={{.State.ExitCode}} started={{.State.StartedAt}} finished={{.State.FinishedAt}}' \
    2>&1 || true
  echo "=== docker logs: ${container} ==="
  /usr/bin/docker logs --tail 200 "${container}" 2>&1 || true
done

# ── Envoy routing diagnostics ────────────────────────────────────────────────
# The echo-mcp-smoke probe (`initialize`, no Mcp-Session-Id) fails with a 404
# from envoy. The docker logs above include envoy's access log, whose format
# (see payload/envoy/lds/listener.yaml) carries %RESPONSE_FLAGS% and
# %RESPONSE_CODE_DETAILS% — those name *why* a request got its status
# (route_not_found / no_route / ext_authz denial / mcp filter reject, etc.).
# The dumps below add envoy's *effective* config so a route-match bug in the
# runtime listener (as rewritten by enable-dummy-auth.sh) is visible directly
# instead of inferred from the source YAML.
echo
echo "=== envoy admin: dynamic route configs (effective routes) ==="
/usr/bin/docker run --rm --network botwork-internal botwork/curl:local \
  -sS 'http://botwork-envoy:9901/config_dump?resource=dynamic_route_configs' 2>&1 || true
echo
echo "=== envoy admin: dynamic listeners (effective listener + match rules) ==="
/usr/bin/docker run --rm --network botwork-internal botwork/curl:local \
  -sS 'http://botwork-envoy:9901/config_dump?resource=dynamic_listeners' 2>&1 || true

# The runtime xDS files the enable-dummy-auth step rewrote on the booted VM.
# These are the on-disk inputs envoy loaded; comparing them against the
# effective config above pinpoints whether a bad edit or a load failure is at
# fault.
for f in \
  /etc/botwork/envoy/lds/listener.yaml \
  /etc/botwork/envoy/ecds/ext_authz.yaml \
  /etc/botwork/envoy/cds/clusters.yaml; do
  echo
  echo "=== runtime envoy config on VM: ${f} ==="
  sudo cat "${f}" 2>&1 || true
done
