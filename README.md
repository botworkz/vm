# botworkz/vm

Standalone Packer build repo for the botspace base VM image.

## Overview

This repo builds a Debian 13 (Trixie) QEMU/KVM image with the base botspace
stack pre-baked. The base stack includes:

- **session-broker** — Rust gRPC ext_proc service (from `botworkz/botwork`)
- **mcp-echo** — baseline MCP plugin (from `botworkz/mcp`)
- **packer-tools** — Packer build container (from `containers/packer-tools/` in this repo)
- **botwork-launcher** + **botwork-tools** Rust binaries (built from `botworkz/botwork`)

No secrets or private repositories are required. All dependencies are public.

## Prerequisites

Clone the two public sibling repos next to this one:

```bash
git clone https://github.com/botworkz/botwork ../botwork
git clone https://github.com/botworkz/mcp ../mcp
```

Install: `docker`, `packer`, `cargo`, `qemu-system-x86_64`, `qemu-img`.

## Build

```bash
# Build and stage all images + binaries, then pack the VM image:
./scripts/pack.sh

# Build with qcow2 compression:
./scripts/pack.sh --compress
```

## Release

Versioning is driven by the root `VERSION` file.

- Set `VERSION` to a clean semver (for example `0.1.0`) and merge to `main`.
- The release workflow builds/publishes `ghcr.io/botworkz/vm/packer-tools` and creates GitHub Release `v<VERSION>` with the compressed qcow2 image attached.
- After publish, automation bumps `VERSION` to the next minor `-dev` (for example `0.2.0-dev`).

Use prerelease values (like `0.2.0-dev`) during normal development; those skip publish.

## Smoke test

```bash
./scripts/test-packed.sh
```

## Directory layout

```
compose.yaml               # Docker Compose: packer-tools service mounts ./ as /workspace
containers/packer-tools/   # Dockerfile for the in-repo packer-tools image
envoy/                     # Envoy bootstrap + file-based xDS configs
images/                    # Packer template, cloud-init, provisioner scripts, goss spec
scripts/                   # Build + test entrypoints and lib helpers
systemd/                   # Base systemd units (no auth-broker)
```

## Base-stack security model (no-auth)

- This base stack has **no authentication and no tenant isolation**. It runs
  one fixed server-set tenant: `mcp`.
- Do **not** expose this base stack directly to untrusted networks as-is.
- Auth/vault is added by a separate private overlay composition; this repo
  intentionally omits that overlay, including the auth-broker unit and any
  vault directory creation.
- The auth seam is a fixed ECDS slot in `envoy/lds/listener.yaml`:
  `envoy.filters.http.ext_authz` is pinned before `envoy.filters.http.lua`.
  The base ships a benign default at `envoy/ecds/ext_authz.yaml` that keeps
  the filter disabled (`filter_enabled.default_value.numerator: 0`), so the
  base starts and serves with no authn/z while preserving the seam contract.

## Envoy file-based xDS layout

```
envoy/envoy.yaml          # bootstrap: admin + filesystem LDS/CDS pointers
envoy/lds/listener.yaml   # listener + HTTP filter chain + routes
envoy/cds/clusters.yaml   # base clusters (no auth_broker)
envoy/ecds/ext_authz.yaml # base default for ext_authz seam (disabled)
```

`envoy/envoy.yaml` must stay overlay-agnostic: no inline ext_authz filter
config and no `auth_broker` cluster.

## Overlay file/path contract (private overlay)

The private auth/vault overlay must only swap files over these fixed paths:

- `/etc/envoy/ecds/ext_authz.yaml` — replace base disabled default with real
  `envoy.filters.http.ext_authz` config that sets trusted `x-botwork-tenant`
  from vault-unlock-derived identity.
- `/etc/envoy/cds/clusters.yaml` — replace/extend base clusters with overlay
  `auth_broker` STRICT_DNS cluster.

Contract details that must not drift:

- Filter name: `envoy.filters.http.ext_authz`
- Fixed filter position: before `envoy.filters.http.lua`
- ECDS file path: `/etc/envoy/ecds/ext_authz.yaml`
- ECDS `type_urls`: `type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz`
- CDS file path: `/etc/envoy/cds/clusters.yaml`

The overlay must never edit `envoy/envoy.yaml`.
