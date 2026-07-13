#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[enable-dummy-auth] $*"
}

# Test-only boundary: this script is uploaded by test-packed.yaml after the
# qcow2 has already booted. Nothing here is baked into the published image.
#
# Reachability: the stub runs as a container directly on botwork-internal with
# --network-alias auth_broker, exactly like every other broker unit. Both
# consumers live inside docker networks:
#   (a) session-broker (on botwork-internal) calls http://auth_broker:9100/secrets/fetch
#   (b) envoy ext_authz dials the dummy_auth_broker cluster -> auth_broker:9100
#       with path_prefix /auth/check PREPENDED to the request path, i.e.
#       POST /auth/check/<tenant>/<workspace>/<plugin>
# The dummy-auth-broker:test image is built on the host in scripts/test-packed.sh,
# saved to build/dummy-auth-broker.tar, and uploaded here for docker load.

log "loading dummy auth broker image"
sudo docker load -i /tmp/dummy-auth-broker.tar

log "starting dummy auth broker container on botwork-internal"
sudo docker rm -f dummy-auth-broker >/dev/null 2>&1 || true
sudo docker run -d --rm \
  --name dummy-auth-broker \
  --network botwork-internal \
  --network-alias auth_broker \
  dummy-auth-broker:test

log "waiting for dummy auth broker to accept connections"
# `docker run -d` returns as soon as the container is created, before the
# Python server inside it has bound :9100. A single curl races the bind and
# fails with "(7) ... after 0 ms". Retry until it is listening.
for attempt in $(seq 1 30); do
  if sudo docker run --rm --network botwork-internal botwork/curl:local \
       -sS --max-time 2 -o /dev/null \
       -X POST http://auth_broker:9100/secrets/fetch \
       -H 'x-botwork-cap: dummy-auth-broker-cap' >/dev/null 2>&1; then
    log "dummy auth broker is up (attempt ${attempt})"
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    log "dummy auth broker never became ready"
    sudo docker logs dummy-auth-broker >&2 2>&1 || true
    exit 1
  fi
  sleep 1
done

log "verifying dummy auth broker contracts"
# ext_authz /auth/check leg: envoy prepends path_prefix, so the real check
# arrives as /auth/check/<...>. Probe that shape (not a bare /auth/check) so
# this contract matches what envoy actually sends and mints x-botwork-cap.
auth_headers="$(sudo docker run --rm --network botwork-internal botwork/curl:local \
  -sS --max-time 5 -D - -o /dev/null -X POST http://auth_broker:9100/auth/check/mcp/demo/echo)"
printf '%s\n' "${auth_headers}" | grep -iq '^x-botwork-cap: .\+' \
  || { printf '%s\n' "${auth_headers}" >&2; exit 1; }
# session-broker /secrets/fetch leg: called with the exact path and a
# non-empty cap; body must be the fixed no-secrets fixture.
secrets_body="$(sudo docker run --rm --network botwork-internal botwork/curl:local \
  -sS --max-time 5 -X POST http://auth_broker:9100/secrets/fetch \
  -H 'x-botwork-cap: dummy-auth-broker-cap')"
[[ "${secrets_body}" == '{"tenant":"mcp","plugin":"echo","secrets":[]}' ]]
# The cap gate is present-and-non-empty, not an exact literal: a different
# non-empty cap (as session-broker's real ext_authz token would be) still 200s.
alt_secrets_body="$(sudo docker run --rm --network botwork-internal botwork/curl:local \
  -sS --max-time 5 -X POST http://auth_broker:9100/secrets/fetch \
  -H 'x-botwork-cap: some-other-non-empty-cap')"
[[ "${alt_secrets_body}" == '{"tenant":"mcp","plugin":"echo","secrets":[]}' ]]

log "overwriting runtime envoy auth seam config"
sudo tee /etc/botwork/envoy/ecds/ext_authz.yaml >/dev/null <<'YAML'
resources:
- "@type": type.googleapis.com/envoy.config.core.v3.TypedExtensionConfig
  name: envoy.filters.http.ext_authz
  typed_config:
    "@type": type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz
    filter_enabled:
      runtime_key: botwork.base.ext_authz.enabled
      default_value:
        numerator: 100
        denominator: HUNDRED
    http_service:
      server_uri:
        uri: http://auth_broker:9100
        cluster: dummy_auth_broker
        timeout: 5s
      path_prefix: /auth/check
      authorization_request:
        allowed_headers:
          patterns:
          - exact: content-type
          - exact: mcp-session-id
          - exact: x-botwork-tenant
      authorization_response:
        allowed_upstream_headers:
          patterns:
          - exact: x-botwork-cap
    transport_api_version: V3
    failure_mode_allow: false
YAML

sudo tee /etc/botwork/envoy/cds/clusters.yaml >/dev/null <<'YAML'
resources:
- "@type": type.googleapis.com/envoy.config.cluster.v3.Cluster
  name: session_broker_grpc
  connect_timeout: 5s
  type: STRICT_DNS
  dns_lookup_family: V4_ONLY
  typed_extension_protocol_options:
    envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
      "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
      explicit_http_config:
        http2_protocol_options: {}
  load_assignment:
    cluster_name: session_broker_grpc
    endpoints:
    - lb_endpoints:
      - endpoint:
          address:
            socket_address:
              address: session_broker
              port_value: 9001

- "@type": type.googleapis.com/envoy.config.cluster.v3.Cluster
  name: dummy_auth_broker
  connect_timeout: 5s
  type: STRICT_DNS
  dns_lookup_family: V4_ONLY
  load_assignment:
    cluster_name: dummy_auth_broker
    endpoints:
    - lb_endpoints:
      - endpoint:
          address:
            socket_address:
              address: auth_broker
              port_value: 9100

- "@type": type.googleapis.com/envoy.config.cluster.v3.Cluster
  name: dynamic_forward_proxy_cluster
  connect_timeout: 5s
  lb_policy: CLUSTER_PROVIDED
  cluster_type:
    name: envoy.clusters.dynamic_forward_proxy
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.clusters.dynamic_forward_proxy.v3.ClusterConfig
      dns_cache_config:
        name: dynamic_forward_proxy_cache_config
        dns_lookup_family: V4_ONLY
YAML

log "restarting botwork-envoy with dummy auth seam enabled"
sudo systemctl restart botwork-envoy
sudo systemctl is-active --quiet botwork-envoy
