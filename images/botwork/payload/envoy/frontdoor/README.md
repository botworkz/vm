# Frontdoor FS-xDS overlay seam contract

This directory contains the base file-based xDS configuration for
`botwork-envoy-frontdoor`. It is intentionally minimal: the base default
boots the VM into "serving holding page" mode.

## Files

| Path (inside container) | Host path | Purpose |
|---|---|---|
| `/etc/envoy/envoy.yaml` | `/etc/botwork/envoy/frontdoor/envoy.yaml` | Immutable bootstrap. Admin `:9903` inside container (not published to host). |
| `/etc/envoy/lds/listener.yaml` | `/etc/botwork/envoy/frontdoor/lds/listener.yaml` | `:80` HCM listener. References RDS route config `frontdoor_routes` from `rds/active.yaml`. |
| `/etc/envoy/cds/clusters.yaml` | `/etc/botwork/envoy/frontdoor/cds/clusters.yaml` | Two clusters: `holding` (docker DNS `botwork-frontdoor-holding`) and `ingress` (docker DNS `botwork-envoy`). |
| `/etc/envoy/rds/active.yaml` | `/etc/botwork/envoy/frontdoor/rds/active.yaml` | **The spigot file.** Base: all traffic → `holding`. Override: swap to route to `ingress`. |

## Overlay contract

Overlays (`botworkz/space`) MUST only swap `/etc/botwork/envoy/frontdoor/rds/active.yaml`
(and optionally `cds/clusters.yaml` if upstream addresses change). They MUST NOT
edit `envoy.yaml` or `lds/listener.yaml`.

The route config name `frontdoor_routes` is pinned. Any replacement `rds/active.yaml`
must use the same name.

## Why frontdoor is NOT wired to control-plane

Control-plane lives inside the botwork stack. Frontdoor must be able to serve
when the stack is down (masked, restarting, broken). Frontdoor stays FS-xDS
permanently — this is load-bearing, do not "add an ADS stream for symmetry".

## Spigot flip

To route live traffic to the ingress cluster (go-live), write the replacement config
to a temporary file on the same filesystem, then atomically rename it into place:

```sh
# write replacement to a tmp file on the same filesystem
cp /dev/stdin /etc/botwork/envoy/frontdoor/rds/active.yaml.new <<'EOF'
resources:
- "@type": type.googleapis.com/envoy.config.route.v3.RouteConfiguration
  name: frontdoor_routes
  virtual_hosts:
  - name: frontdoor
    domains: ["*"]
    routes:
    - match:
        prefix: "/"
      route:
        cluster: ingress
EOF

# atomic rename — the ONLY reliable way to trigger Envoy FS xDS reload
mv /etc/botwork/envoy/frontdoor/rds/active.yaml.new \
   /etc/botwork/envoy/frontdoor/rds/active.yaml
```

**`mv` (atomic rename) is the only supported update method.** Envoy's FS xDS watcher
fires on `IN_MOVED_TO` — the inotify event emitted by a same-filesystem rename.

- `cp` or writing in place: does **not** trigger a reload.
- Symlinks: do **not** work — Envoy watches the path, not what a symlink resolves to.
