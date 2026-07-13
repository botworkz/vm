# botwork

Debian 13 (Trixie) qcow2 image with the base botwork stack pre-baked.

Builds on top of `botwork-docker` as declared in
[`images/manifest.yaml`](../../images/manifest.yaml).
Output file: `debian-13-botwork.qcow2`.

## Base stack

The following components are baked into the image:

- **session-broker** — Rust gRPC ext_proc service ([`botworkz/botwork`](https://github.com/botworkz/botwork))
- **config-broker** — Rust HTTP plugin-registry resolver ([`botworkz/botwork`](https://github.com/botworkz/botwork))
- **control-plane** — Rust HTTP per-session policy store, gates spawn ([`botworkz/botwork`](https://github.com/botworkz/botwork))
- **postgres** — Persistence-layer DB ([upstream `postgres:16-bookworm`](https://hub.docker.com/_/postgres), digest-pinned in `shasset.yaml`)
- **db-migrate** — Persistence-layer migration oneshot, runs SeaORM `Migrator::up` at boot ([`botworkz/botwork`](https://github.com/botworkz/botwork))
- **mcp-echo** — baseline MCP plugin ([`botworkz/mcp`](https://github.com/botworkz/mcp))
- **botwork-launcher** + **botwork-tools** — Rust binaries installed under `/usr/local/bin/` ([`botworkz/botwork`](https://github.com/botworkz/botwork))
- **Envoy (ingress)** — `botwork-envoy` HTTP proxy with file-based xDS config, publishes `:8080` (see [Envoy xDS layout](#envoy-file-based-xds-layout) below)
- **Envoy (egress)** — `botwork-egress-envoy` forward proxy for plugin containers, xDS from control-plane

No secrets or private repositories are required. All dependencies are public.

Container images are pulled via `shasset`, staged into the image during `botforge build`,
loaded into docker during the same build, and the staged tarballs are stripped before commit.
Rust binaries are downloaded as release assets and installed under `/usr/local/bin/`.
See the top-level [dependency model](../../README.md#dependency-model) for how pins in
`shasset.yaml` are resolved.

### Image tag contract

The image build loads each base image from a tar under `build/images/baked/` and **deterministically retags it** to `botwork/<svc>:local` so the systemd units (`botwork-session-broker.service`, etc.) bind to a stable tag regardless of what `RepoTags` was in the tar. Those base tarballs are then removed before commit, so the published qcow2 carries the base stack images once (in `/var/lib/docker`), not twice.

At boot, `botwork-image-loader.service` loads any tar dropped under
`/usr/share/botwork/images/<name>.tar` and retags it to
`botwork/<name>:local`. Child layers built on top of
`botwork-vm-${VERSION}.qcow2` can rely on this: stage additional tarballs
into the same well-known directory at build time and the parent layer's
loader will pick them up. There is no need to ship a sibling image-loader
oneshot.

For the published base stack, the loader normally takes the no-op path
(`all images present`) because those tags are already in docker and the
base tarballs have been stripped.

Redeploy topology note: base-stack images now live only in the boot disk's
docker store (`/var/lib/docker`) and no longer as local base tarballs. A
flow that recreates the boot disk while keeping a persistent
`/var/lib/botwork` data disk comes up with images already present only when
the recreated boot disk is this published botwork qcow2 (which ships the
preloaded docker store).

Sibling-mode builds (`BOTWORK_TOOLS_IMAGES_REF=sibling`, `BOTWORKZ_MCP_IMAGES_REF=sibling`) are for **local iteration only** and are rejected by CI. Production qcow2s are always baked from the `oci://` pins in `shasset.yaml`.

CI asserts at validate time that every on-disk tar's image config sha matches the `digest:` in `shasset.yaml`, and the smoke test asserts at runtime that `botwork/<svc>:local` resolves to the same image config sha as the corresponding `ghcr.io/...` tag on disk.

## Build

```bash
# Build this image (botwork is the default):
./scripts/pack.sh

# Equivalent explicit invocation:
./scripts/pack.sh botwork

# With qcow2 compression:
./scripts/pack.sh --compress

# Build just this layer on top of a published parent artifact:
./scripts/pack.sh botwork --compress --source build/debian-13-botwork-docker-compressed.qcow2
```

Run from the repo root.

## Smoke test

```bash
# Run the smoke test for this image (botwork is the default):
./scripts/test-packed.sh

# Equivalent explicit invocation:
./scripts/test-packed.sh botwork
```

The smoke test runs [`test/goss.yaml`](test/goss.yaml) (service/file/port assertions)
and [`test/mcp-echo-smoke.sh`](test/mcp-echo-smoke.sh) (end-to-end MCP echo check)
inside the packed image via the `botforge` container.

## Security model — no auth, no tenant isolation

- This base stack has **no authentication and no tenant isolation**. It runs
  one fixed server-set tenant: `mcp`.
- Do **not** expose this base stack directly to untrusted networks as-is.
- Auth/vault is added by a separate private overlay composition; this repo
  intentionally omits that overlay, including the auth-broker unit and any
  vault directory creation.
- The auth seam is a fixed ECDS slot in
  [`payload/envoy/lds/listener.yaml`](payload/envoy/lds/listener.yaml):
  `envoy.filters.http.ext_authz` is pinned before `envoy.filters.http.lua`.
  The base ships a benign default at
  [`payload/envoy/ecds/ext_authz.yaml`](payload/envoy/ecds/ext_authz.yaml)
  that keeps the filter disabled (`filter_enabled.default_value.numerator: 0`),
  so the base starts and serves with no authn/z while preserving the seam contract.

## Network topology

Two docker networks are created at boot:

| Container | botwork-internal | botwork-plugin | Host-published |
|---|:-:|:-:|---|
| `botwork-envoy` (ingress) | ✓ | ✓ | `0.0.0.0:8080` |
| `botwork-egress-envoy` | | ✓ | — |
| brokers (config / session / auth / control-plane) | ✓ | | — |
| plugin session containers | | ✓ | — |

Networks:

- **`botwork-internal`** — brokers only (config-broker, session-broker, control-plane, api, ui, postgres)
- **`botwork-plugin`** — spawned MCP plugin containers; ingress envoy and egress envoy bridge the two

Public L7 ingress (TLS termination, holding page, ACME) is an operational concern that
belongs in the deployment overlay, not in this base image. See `botworkz/space` for the
reference contabo implementation.

## Envoy file-based xDS layout

```
payload/envoy/envoy.yaml              # bootstrap: admin + filesystem LDS/CDS pointers (ingress)
payload/envoy/lds/listener.yaml       # listener + HTTP filter chain + routes
payload/envoy/cds/clusters.yaml       # base clusters (no auth_broker)
payload/envoy/ecds/ext_authz.yaml     # base default for ext_authz seam (disabled)
```

[`payload/envoy/envoy.yaml`](payload/envoy/envoy.yaml) must stay overlay-agnostic:
no inline ext_authz filter config and no `auth_broker` cluster.

## Overlay file/path contract (private overlay)

The private auth/vault overlay must only swap `/etc/envoy/ecds/ext_authz.yaml`
and `/etc/envoy/cds/clusters.yaml` on the running VM.
It must never edit [`payload/envoy/envoy.yaml`](payload/envoy/envoy.yaml).

Contract details that must not drift:

| Concern | Pinned value |
|---------|-------------|
| Filter name | `envoy.filters.http.ext_authz` |
| Filter position | before `envoy.filters.http.lua` |
| ECDS file path | `/etc/envoy/ecds/ext_authz.yaml` |
| ECDS `type_urls` | `type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz` |
| CDS file path | `/etc/envoy/cds/clusters.yaml` |

## Layout

```
build.yaml            # botforge build spec (booted KVM + SSH provisioner)
payload/envoy/        # Envoy bootstrap + file-based xDS configs (ingress)
payload/systemd/      # systemd unit files baked into the image
test/                 # goss spec (goss.yaml) + smoke-test scripts
```
