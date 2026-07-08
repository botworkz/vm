# botworkz/vm

Image build repo for Debian 13 (Trixie) QEMU/KVM qcow2s.

Images are declared in [`images/manifest.yaml`](images/manifest.yaml) and built
via the pinned `botforge` container, which bundles `virt-customize` from
libguestfs. There is no host Packer install, no HCL, no cloud-init seed at
build time, and no ephemeral SSH key for the build path. The smoke test boots
the produced qcow2 under qemu and uses botforge's ephemeral installer to SSH
in, so no pre-shared key is needed at test time either.

## Images

| Name | Parent | Output | Description |
|------|--------|--------|-------------|
| [`botwork-base`](images/botwork-base/) | — | `botwork-base.qcow2` | Minimal Debian 13 Trixie cloud image with base provisioning |
| [`botwork-docker`](images/botwork-docker/) | `botwork-base` | `debian-13-botwork-docker.qcow2` | Debian 13 Trixie image with Docker CE and the `bot` user in the `docker` group |
| [`botwork`](images/botwork/) | `botwork-docker` | `debian-13-botwork.qcow2` | Debian 13 Trixie image with the full botwork stack pre-baked ([details](images/botwork/README.md)) |

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

For the scripted build/smoke-test entrypoints, install `docker` (for `docker
compose`) and use a host with `/dev/kvm` available. The host docker daemon is
only used to run the `botforge` container and (in `sibling` mode only) to
`docker save` earthly-built images; `botforge` itself does not talk to the
host daemon.

`/dev/kvm` is required for the smoke test (`botforge test` boots a real qemu
VM) and strongly preferred for the build (libguestfs uses KVM for the
supermin appliance, falls back to TCG without it).

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
# Build the default image (botwork) via botforge + virt-customize:
./scripts/pack.sh

# Build a specific image:
./scripts/pack.sh <image-name>

# Build with qcow2 compression:
./scripts/pack.sh --compress
./scripts/pack.sh <image-name> --compress

# Build a single layer on top of a prebuilt parent artifact:
./scripts/pack.sh botwork-docker --source build/botwork-base-compressed.qcow2
```

`scripts/pack.sh` downloads the upstream Debian cloud qcow2 into
`build/cache/` (verifying it against the matching `SHA512SUMS`), then walks
the image's parent chain in `images/manifest.yaml` and invokes
`botforge build-legacy --spec images/<name>/build.yaml` inside the botforge
container for each link. Each `build.yaml` is a declarative virt-customize
spec (see [botforge `build-legacy` docs](https://github.com/botworkz/tools/blob/main/botforge/README.md#botforge-build-legacy-spec-format))
that runs the layer-local provisioner scripts under
`images/<name>/provisioners/` against the staged source qcow2. When
`--source <qcow2>` is supplied, `pack.sh` skips the chain walk and builds
only the named layer on top of that artifact.

## Release

Versioning is driven by the root `VERSION` file.

- Set `VERSION` to a clean semver (for example `0.1.0`) and merge to `main`.
- The release workflow creates GitHub Release `v<VERSION>` and publishes all three qcow2 assets under that same tag:
  - `botwork-base-vm-${VERSION}.qcow2`
  - `botwork-docker-vm-${VERSION}.qcow2`
  - `botwork-vm-${VERSION}.qcow2`
- After publish, automation bumps `VERSION` to the next minor `-dev` (for example `0.2.0-dev`).

Use prerelease values (like `0.2.0-dev`) during normal development; those skip publish.

## Smoke test

```bash
# Run the smoke test for the default image (botwork) via botforge:
./scripts/test-packed.sh

# Run the smoke test for a specific image:
./scripts/test-packed.sh <image-name>
```

The smoke test boots the produced qcow2 under qemu with a cidata seed ISO.
botforge provisions and SSHes in as its own **ephemeral installer user**
(generated per run, with an ephemeral keypair injected via the cidata seed) —
no pre-shared key or specific user account is required at test time. It then
runs the steps declared in `images/<name>/test/test-packed.yaml` (goss spec +
per-image end-to-end checks).

## Directory layout

```
deps/container/            # Pinned botforge container definition
images/<name>/             # Per-image build spec, payload, and tests
  build.yaml               #   botforge build-legacy spec (virt-customize driver)
  provisioners/            #   Layer-local guest provisioning scripts
  payload/                 #   Files baked into the resulting qcow2
  test/                    #   Per-image goss spec + smoke-test plan
images/manifest.yaml       # Image set declaration + parent DAG
scripts/                   # Thin bash entrypoints that delegate to botforge
shasset.yaml               # Pinned binary release + container image digests
```
