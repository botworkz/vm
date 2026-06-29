# Frontdoor FS-xDS overlay seam contract

This directory contains the base file-based xDS configuration for
`botwork-envoy-frontdoor`. It is intentionally minimal: the base default
boots the VM into "serving holding page" mode via Envoy `direct_response` —
no upstream container required.

## Files

| Path (inside container) | Host path | Purpose |
|---|---|---|
| `/etc/envoy/envoy.yaml` | `/run/botwork/frontdoor/envoy.yaml` | Effective bootstrap rendered at service start from immutable `envoy.yaml` plus `bootstrap_extensions.yaml`. Admin `:9903` inside container (not published to host). |
| `/etc/botwork/envoy/frontdoor/envoy.yaml` | `/etc/botwork/envoy/frontdoor/envoy.yaml` | Immutable bootstrap template. Do not edit; the host-side renderer consumes it. |
| `/etc/envoy/lds/active.yaml` | `/etc/botwork/envoy/frontdoor/lds/active.yaml` | **The live LDS seam.** Base ships `:80` + inert `:443`; overlays atomically swap this file to change listener/filter shape. |
| `/etc/envoy/lds/listener.yaml` | `/etc/botwork/envoy/frontdoor/lds/listener.yaml` | Immutable reference copy of the base listener set. Do not edit. |
| `/etc/envoy/cds/clusters.yaml` | `/etc/botwork/envoy/frontdoor/cds/clusters.yaml` | One cluster: `ingress` (docker DNS `botwork-envoy`). |
| `/etc/envoy/rds/active.yaml` | `/etc/botwork/envoy/frontdoor/rds/active.yaml` | **The spigot file.** Base: `direct_response` 200 with holding HTML. Override: swap to route to `ingress`. |
| `/etc/envoy/sds/active.yaml` | `/etc/botwork/envoy/frontdoor/sds/active.yaml` | TLS secret via filesystem SDS. Base points at placeholder cert/key so Envoy binds `:443` cleanly. |
| `/etc/envoy/modules/` | `/etc/botwork/envoy/frontdoor/modules/` | Dynamic-module search path. Empty in the base image. |
| n/a (host-side fragment) | `/etc/botwork/envoy/frontdoor/bootstrap_extensions.yaml` | Optional bootstrap extension fragment inserted into the rendered bootstrap at service start. |
| n/a (host-side state dir) | `/var/lib/botwork/frontdoor/acme/` | Writable state surface for overlay-managed certificate material and related state. |

## Overlay contract

Overlays (`botworkz/space`) MUST NOT edit `envoy.yaml` or `lds/listener.yaml`.
They MAY:

- atomically swap `/etc/botwork/envoy/frontdoor/rds/active.yaml`,
- atomically swap `/etc/botwork/envoy/frontdoor/lds/active.yaml`,
- atomically swap `/etc/botwork/envoy/frontdoor/sds/active.yaml`,
- atomically swap `/etc/botwork/envoy/frontdoor/bootstrap_extensions.yaml`
  followed by a `botwork-envoy-frontdoor.service` restart,
- update `cds/clusters.yaml` if upstream addresses change,
- drop module `.so` files into `/etc/botwork/envoy/frontdoor/modules/`,
- write overlay-owned state under `/var/lib/botwork/frontdoor/acme/`.

The route config name `frontdoor_routes` is pinned. Any replacement `rds/active.yaml`
must use the same name.

## Listener `:443`

The base image now ships an inert HTTPS listener on `:443`. It always binds and
completes the TLS handshake using a placeholder self-signed certificate exposed
through filesystem SDS. Until an overlay activates real TLS handling, the base
listener returns:

- `503 Service Unavailable`
- `content-type: text/plain; charset=utf-8`
- body `TLS not yet configured`

## Why frontdoor is NOT wired to control-plane

Control-plane lives inside the botwork stack. Frontdoor must be able to serve
when the stack is down (masked, restarting, broken). Frontdoor stays FS-xDS
permanently — this is load-bearing, do not "add an ADS stream for symmetry".

## Overlay seams (additions)

New generic seams added for TLS / dynamic-module overlays:

| Path | Update mode | Notes |
|---|---|---|
| `/etc/botwork/envoy/frontdoor/bootstrap_extensions.yaml` | atomic `mv` + service restart | Host-side fragment inserted into the rendered bootstrap. Use for top-level `bootstrap_extensions` only. |
| `/etc/botwork/envoy/frontdoor/lds/active.yaml` | atomic `mv` | Live listener seam. Use when overlays need to change HTTP filters or listener shape. |
| `/etc/botwork/envoy/frontdoor/sds/active.yaml` | atomic `mv` | Filesystem-SDS secret resource. Base points at placeholder cert/key; overlays can point at real cert/key files. |
| `/etc/botwork/envoy/frontdoor/modules/` | file drop | Dynamic module `.so` search path, mounted read-only into the container at `/etc/envoy/modules/`. |
| `/var/lib/botwork/frontdoor/acme/` | regular writes | Writable overlay-owned state dir, owned by uid:gid `101:101`. |

There is intentionally **no** additive `filters.d/` fragment seam in the base
image. Envoy v1.38 does not offer a clean filesystem-xDS splice point for
appending HTTP filters into an existing HCM chain, so the live listener seam is
`lds/active.yaml`: overlays replace the whole listener resource set there when
they need filter changes.

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
subscribes exclusively to `IN_MOVED_TO` — the inotify event emitted by a
same-filesystem `rename()` syscall. Source:
`source/extensions/config_subscription/filesystem/filesystem_subscription_impl.cc`.

- `cp` or any in-place write: emits `IN_MODIFY`, which Envoy does **not** subscribe
  to by default. Does **not** trigger a reload.
- `ln -sf` / updating a symlink target: emits `IN_DELETE` + `IN_CREATE`, not
  `IN_MOVED_TO`. Does **not** trigger a reload.

The same atomic-rename rule applies to `lds/active.yaml` and `sds/active.yaml`.
`bootstrap_extensions.yaml` is the one exception: Envoy consumes that material
only at process start, so after an atomic rename you must restart
`botwork-envoy-frontdoor.service` to have the host-side renderer rebuild the
effective bootstrap under `/run/botwork/frontdoor/envoy.yaml`.
