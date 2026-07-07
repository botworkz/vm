#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[enable-dummy-auth] $*"
}

log "installing test-only dummy auth broker assets"
sudo install -m 0755 /tmp/dummy-auth-broker.py /usr/local/bin/dummy-auth-broker

# Test-only boundary: this script is uploaded by test-packed.yaml after the qcow2
# has already booted. Nothing here is baked into the published image.
#
# Reachability mechanism:
#   * The stub itself is the required ~30-line stdlib-only Python server.
#   * The baked botwork/postgres:local image is already present on the guest, but
#     (per the probe below) it does not ship python3, so we cannot run the stub
#     directly inside botwork-internal.
#   * Instead we run the Python stub on the guest and expose it to containers via
#     a tiny TCP proxy container on botwork-internal aliased auth_broker. The
#     proxy uses perl because that runtime is already present in botwork/postgres:local.
if sudo docker run --rm botwork/postgres:local python3 --version >/dev/null 2>&1; then
  log "botwork/postgres:local unexpectedly has python3; this script assumes the proxy fallback"
  exit 1
fi

log "starting host-side dummy auth broker"
sudo pkill -f '/usr/local/bin/dummy-auth-broker' >/dev/null 2>&1 || true
sudo rm -f /run/dummy-auth-broker.pid /var/log/dummy-auth-broker.log
sudo sh -c 'nohup /usr/bin/python3 /usr/local/bin/dummy-auth-broker >/var/log/dummy-auth-broker.log 2>&1 & echo $! >/run/dummy-auth-broker.pid'

log "writing botwork-internal proxy for auth_broker alias"
cat <<'PERL' | sudo tee /tmp/dummy-auth-broker-proxy.pl >/dev/null
use IO::Socket::INET;

my $listener = IO::Socket::INET->new(
  LocalAddr => '0.0.0.0',
  LocalPort => 9100,
  Proto     => 'tcp',
  Listen    => 16,
  ReuseAddr => 1,
) or die "listen failed: $!";

while (my $client = $listener->accept) {
  my $upstream = IO::Socket::INET->new(
    PeerAddr => 'host.docker.internal:9100',
    Proto    => 'tcp',
  ) or do {
    close $client;
    next;
  };
  $client->autoflush(1);
  $upstream->autoflush(1);
  my $pid = fork();
  if (!defined $pid) {
    close $client;
    close $upstream;
    next;
  }
  if ($pid == 0) {
    while (sysread($client, my $buf, 8192)) {
      syswrite($upstream, $buf);
    }
    exit 0;
  }
  while (sysread($upstream, my $buf, 8192)) {
    syswrite($client, $buf);
  }
  waitpid($pid, 0);
  close $client;
  close $upstream;
}
PERL

sudo docker rm -f dummy-auth-broker >/dev/null 2>&1 || true
sudo docker run -d --rm \
  --name dummy-auth-broker \
  --network botwork-internal \
  --network-alias auth_broker \
  --add-host host.docker.internal:host-gateway \
  -v /tmp/dummy-auth-broker-proxy.pl:/tmp/dummy-auth-broker-proxy.pl:ro \
  botwork/postgres:local \
  perl /tmp/dummy-auth-broker-proxy.pl >/dev/null

log "verifying dummy auth broker contracts"
auth_headers="$(sudo docker run --rm --network botwork-internal botwork/curl:local \
  -sS -D - -o /dev/null -X POST http://auth_broker:9100/auth/check)"
printf '%s\n' "${auth_headers}" | grep -iq '^x-botwork-cap: .\+' \
  || { printf '%s\n' "${auth_headers}" >&2; exit 1; }
secrets_body="$(sudo docker run --rm --network botwork-internal botwork/curl:local \
  -sS -X POST http://auth_broker:9100/secrets/fetch \
  -H 'x-botwork-cap: dummy-auth-broker-cap')"
[[ "${secrets_body}" == '{"tenant":"mcp","plugin":"echo","secrets":[]}' ]]

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

log "limiting ext_authz to spawn requests only"
sudo python3 - <<'PY'
import copy
import pathlib
import yaml

path = pathlib.Path("/etc/botwork/envoy/lds/listener.yaml")
data = yaml.safe_load(path.read_text(encoding="utf-8"))
route = data["resources"][0]["filter_chains"][0]["filters"][0]["typed_config"]["route_config"]["virtual_hosts"][0]["routes"][0]
spawn_route = copy.deepcopy(route)
spawn_route["match"] = {
    "prefix": "/mcp/",
    "headers": [{"name": "mcp-session-id", "present_match": False}],
}
session_route = copy.deepcopy(route)
session_route.setdefault("typed_per_filter_config", {})["envoy.filters.http.ext_authz"] = {
    "@type": "type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthzPerRoute",
    "disabled": True,
}
data["resources"][0]["filter_chains"][0]["filters"][0]["typed_config"]["route_config"]["virtual_hosts"][0]["routes"] = [
    spawn_route,
    session_route,
]
path.write_text(yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
PY

log "restarting botwork-envoy with dummy auth seam enabled"
sudo systemctl restart botwork-envoy
sudo systemctl is-active --quiet botwork-envoy
