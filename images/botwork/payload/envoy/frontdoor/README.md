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

To route live traffic to the ingress cluster (go-live), write a new `rds/active.yaml`
that routes `prefix: "/"` to `cluster: ingress`. Envoy's FS xDS will notice the
inode change and hot-reload the route config within seconds. Use an atomic rename
(`mv new.yaml active.yaml`) to avoid a partial-read window.
