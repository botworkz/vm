# images/botwork

Debian 13 (Trixie) qcow2 image with the base botwork stack pre-baked.

Builds on top of `debian-base` as declared in
[`images/manifest.yaml`](../../images/manifest.yaml).
Output file: `debian-13-botwork.qcow2`.

## Base stack

The following components are baked into the image:

- **session-broker** — Rust gRPC ext_proc service ([`botworkz/botwork`](https://github.com/botworkz/botwork))
- **mcp-echo** — baseline MCP plugin ([`botworkz/mcp`](https://github.com/botworkz/mcp))
- **botwork-launcher** + **botwork-tools** — Rust binaries installed under `/usr/local/bin/` ([`botworkz/botwork`](https://github.com/botworkz/botwork))
- **Envoy** — HTTP proxy with file-based xDS config (see [Envoy xDS layout](#envoy-file-based-xds-layout) below)

No secrets or private repositories are required. All dependencies are public.

Container images are pulled via `shasset` and `docker load`-ed during the Packer build.
Rust binaries are downloaded as release assets and installed under `/usr/local/bin/`.
See the top-level [dependency model](../../README.md#dependency-model) for how pins in
`shasset.yaml` are resolved.

### Image tag contract

The packer build loads each base image from a tar under `build/images/baked/` and **deterministically retags it** to `botwork/<svc>:local` so the systemd units (`botwork-session-broker.service`, etc.) bind to a stable tag regardless of what `RepoTags` was in the tar.

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

## Envoy file-based xDS layout

```
payload/envoy/envoy.yaml          # bootstrap: admin + filesystem LDS/CDS pointers
payload/envoy/lds/listener.yaml   # listener + HTTP filter chain + routes
payload/envoy/cds/clusters.yaml   # base clusters (no auth_broker)
payload/envoy/ecds/ext_authz.yaml # base default for ext_authz seam (disabled)
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
botwork.pkr.hcl       # Packer template for this image
variables.pkr.hcl     # Per-image variable overrides + defaults
payload/envoy/        # Envoy bootstrap + file-based xDS configs
payload/systemd/      # systemd unit files baked into the image
test/                 # goss spec (goss.yaml) + smoke-test scripts
```
