# botworkz/vm

Standalone Packer build repo for the botwork base VM image.

## Overview

This repo builds a Debian 13 (Trixie) QEMU/KVM image with the base botwork
stack pre-baked. The base stack includes:

- **session-broker** — Rust gRPC ext_proc service (from `botworkz/botwork`)
- **mcp-echo** — baseline MCP plugin (from `botworkz/mcp`)
- **packer-tools** — Packer build container (from `ghcr.io/botworkz/tools/packer-tools` in `botworkz/tools`)
- **botwork-launcher** + **botwork-tools** Rust binaries (from `botworkz/botwork` releases)

No secrets or private repositories are required. All dependencies are public.

## Dependency model

- Non-docker binary pins live in `shasset.yaml` (`url`, `version`, `checksum`).
- Image digest pins live in `deps/container/*.Dockerfile` as:
  `FROM <image>:<tag>@sha256:<digest>`.
- Default dependency resolution is `registry`: images are pulled from GHCR by digest and binaries are fetched + checksum-verified via `ghcr.io/botworkz/tools/shasset`.
- `sibling` remains opt-in (`--mode sibling` or per-component `*_REF=sibling`) and builds from `../botwork`, `../mcp`, and optionally `../tools` via EarthBuild targets (`earthly +<svc>-image`).
- Sibling image builds require the maintained EarthBuild fork (`EarthBuild/earthbuild`) pinned to `v0.8.17`.
- To repin botwork release binaries, run shasset `add --compute` against `shasset.yaml`; to repin container images, update the matching digest pin in `deps/container/*.Dockerfile`.

## Prerequisites

Install: `docker`, `packer`, `cargo`, `qemu-system-x86_64`, `qemu-img`.

For `sibling` mode, clone the public sibling repos next to this one:

```bash
git clone https://github.com/botworkz/botwork ../botwork
git clone https://github.com/botworkz/mcp ../mcp
```

Sibling image builds require the maintained EarthBuild fork (installed as `earthly`), pinned to `v0.8.17` with checksum verification:

```sh
tmp="$(mktemp -d)"
base="https://github.com/EarthBuild/earthbuild/releases/download/v0.8.17"
curl -fsSL -o "${tmp}/earth-linux-amd64" "${base}/earth-linux-amd64"
curl -fsSL -o "${tmp}/checksum.asc" "${base}/checksum.asc"
( cd "${tmp}" && grep ' earth-linux-amd64$' checksum.asc | sha256sum -c - )
sudo install -m 0755 "${tmp}/earth-linux-amd64" /usr/local/bin/earthly
earthly bootstrap
```

Optional: to build `packer-tools` from a sibling checkout instead of pulling from GHCR, clone `botworkz/tools` at `../tools` and set `BOTWORK_PACKER_TOOLS_REF=sibling`.

```bash
git clone https://github.com/botworkz/tools ../tools
export BOTWORK_PACKER_TOOLS_REF=sibling
```

`../tools` is `botworkz/tools` (the `packer-tools` image producer), while `../botwork` is `botworkz/botwork` (session-broker and the launcher/tools Rust binaries).

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
- The release workflow creates GitHub Release `v<VERSION>` with the compressed qcow2 image attached.
- After publish, automation bumps `VERSION` to the next minor `-dev` (for example `0.2.0-dev`).

Use prerelease values (like `0.2.0-dev`) during normal development; those skip publish.

## Smoke test

```bash
./scripts/test-packed.sh
```

## Directory layout

```
compose.yaml               # Docker Compose: packer-tools service mounts ./ as /workspace
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
