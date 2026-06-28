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
