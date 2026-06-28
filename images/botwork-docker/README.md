# images/botwork-docker

Debian 13 (Trixie) qcow2 image with Docker CE installed and the `bot` system user wired into the `docker` group. Layered on top of `botwork-base` per [`images/manifest.yaml`](../../images/manifest.yaml). Output file: `debian-13-botwork-docker.qcow2`.

Published as `botwork-docker-vm-${VERSION}.qcow2` alongside the full `botwork` image on every release.

No botwork binaries, no systemd units beyond Debian + docker defaults, no baked-in container image tarballs. Use this as a parent for downstream overlays that want a Debian VM with Docker pre-installed but bring their own container stack.

## Build

```bash
./scripts/pack.sh botwork-docker
./scripts/pack.sh botwork-docker --compress
```

Run from the repo root.

## Smoke test

```bash
./scripts/test-packed.sh botwork-docker
```

The smoke test runs [`test/goss.yaml`](test/goss.yaml) inside the packed image via the `botforge` container.
