# botworkz/vm

Packer build repo for Debian 13 (Trixie) QEMU/KVM images.

Images are declared in [`images/manifest.yaml`](images/manifest.yaml) and built
via the pinned `botforge` container — no host Packer or Go installation required.

## Images

| Name | Parent | Output | Description |
|------|--------|--------|-------------|
| [`debian-base`](images/debian-base/) | — | `debian-base.qcow2` | Minimal Debian 13 Trixie cloud image with base provisioning |
| [`botwork`](images/botwork/) | `debian-base` | `debian-13-botwork.qcow2` | Debian 13 Trixie image with the base botwork stack pre-baked ([details](images/botwork/README.md)) |

## Dependency model

- All third-party pins (binary release downloads + container image digests) live in `shasset.yaml`.
  - HTTPS release binaries use `https://` URIs with `version` + `checksum:` sha256.
  - Container images use `oci://<registry>/<repo>@sha256:<digest>` URIs; the digest is self-verifying.
- `shasset` (run inside the pinned `botforge` container) pulls everything natively: no host Docker daemon involvement for fetching pinned dependencies.
- The only host-side container pin is the `botforge` image itself, in `deps/container/botforge.Dockerfile`. Bump it manually when a new `ghcr.io/botworkz/tools/botforge` release is out.
- Default dependency resolution is `registry`. `sibling` is opt-in via `BOTWORK_TOOLS_IMAGES_REF=sibling` (uses `../botwork` + EarthBuild) and/or `BOTWORKZ_MCP_IMAGES_REF=sibling` (uses `../mcp`). Sibling mode still requires host-side `docker save` to capture the earthly-built image.
- Sibling image builds require the maintained EarthBuild fork (`EarthBuild/earthbuild`) pinned to `v0.8.17`.
- To repin a release binary or image, hand-edit `shasset.yaml` (or `shasset add --compute <name> --uri ...` for binaries). For images, look up the new digest with `docker buildx imagetools inspect ghcr.io/...:tag` and paste it into the `oci://` URI.

## Prerequisites

For the scripted build/smoke-test entrypoints, install `docker` (for `docker compose`) and use a host with `/dev/kvm` available. The host docker daemon is only used to run the `botforge` container and (in `sibling` mode only) to `docker save` earthly-built images; `botforge` itself does not talk to the host daemon.

For local validation outside the wrappers, install `packer`.

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

## Build

```bash
# Build the default image (botwork) via botforge:
./scripts/pack.sh

# Build a specific image:
./scripts/pack.sh <image-name>

# Build with qcow2 compression:
./scripts/pack.sh --compress
./scripts/pack.sh <image-name> --compress
```

## Release

Versioning is driven by the root `VERSION` file.

- Set `VERSION` to a clean semver (for example `0.1.0`) and merge to `main`.
- The release workflow creates GitHub Release `v<VERSION>` with the compressed qcow2 image attached.
- After publish, automation bumps `VERSION` to the next minor `-dev` (for example `0.2.0-dev`).

Use prerelease values (like `0.2.0-dev`) during normal development; those skip publish.

## Smoke test

```bash
# Run the smoke test for the default image (botwork) via botforge:
./scripts/test-packed.sh

# Run the smoke test for a specific image:
./scripts/test-packed.sh <image-name>
```

## Directory layout

```
deps/container/            # Pinned botforge container definition
images/<name>/             # Per-image Packer template, payload, and tests
  <name>.pkr.hcl           #   Packer template
  variables.pkr.hcl        #   Per-image variable overrides + defaults
  payload/                 #   Files baked into the resulting qcow2
  test/                    #   Per-image goss spec + smoke-test plan
images/_shared/            # Shared provisioners + cloud-init bootstrap
images/manifest.yaml       # Image set declaration + parent DAG
scripts/                   # Thin bash entrypoints that delegate to botforge
shasset.yaml               # Pinned binary release + container image digests
```
