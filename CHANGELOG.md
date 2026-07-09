# Changelog

## [Unreleased]

### Changed

- `images/botwork/provisioners/20-botwork-stack.sh`: botwork vendor unit files
  are now installed into `/usr/lib/systemd/system/` (the systemd vendor path)
  instead of `/etc/systemd/system/` (the admin/override directory).

  `/etc/systemd/system/` is intentionally left free for admin overrides and
  mask symlinks. As a result, `systemctl mask <unit>` now works without any
  move-aside workaround: masking creates `/etc/systemd/system/<unit> →
  /dev/null` and shadows the vendor copy cleanly — at deploy time, from
  cloud-init `bootcmd`, and offline.

  Enablement is unaffected: `systemctl enable` resolves units by name across
  all load paths and still writes its `.wants` symlinks under
  `/etc/systemd/system/*.wants/`.

  **Downstream overlays** that install their own unit files under
  `/etc/systemd/system/` and previously relied on same-path clobber of the
  vm-baked copy should relocate those files to `/usr/lib/systemd/system/` as
  well. This is the base-image half of the masking fix; the space-side overlay
  relocation and workaround removal are a separate follow-up.

- `images/botwork/test/goss.yaml`: updated unit file-path assertions from
  `/etc/systemd/system/` to `/usr/lib/systemd/system/`; added a `command:`
  assertion that exercises `systemctl mask` / `is-enabled` / `unmask` on
  `botwork-network.service` to prove the "file already exists" failure is gone.

## [0.7.0] - 2026-07-04

### Breaking change

Removed frontdoor (envoy-frontdoor + network-ingress + envoy-acme + placeholder cert).

`botworkz/vm` is the reference deployment of the botwork system. Frontdoor is an
operational concern that belongs downstream in the deployment overlay, not on the
base image. `botworkz/space#399` landed frontdoor ownership end-to-end into
space's contabo pipeline; vm no longer needs to ship it.

**Consumers that rely on vm to provide frontdoor units will break.** Provide your
own frontdoor overlay. See `botworkz/space#399` for the reference implementation.

### Deleted

- `images/botwork/payload/systemd/botwork-envoy-frontdoor.service`
- `images/botwork/payload/systemd/botwork-network-ingress.service`
- `images/botwork/payload/firstboot/botwork-render-frontdoor-envoy`
- `images/botwork/payload/envoy/frontdoor/` (entire tree)
- `shasset.yaml` `envoy-acme:` entry (libenvoy_acme.so fetch belongs to space now)

### Changed

- `images/botwork/provisioners/20-botwork-stack.sh`: removed frontdoor dir
  creation, openssl placeholder-cert generation, libenvoy_acme.so install,
  botwork-render-frontdoor-envoy install, and frontdoor units from the
  `systemctl enable` list.
- `images/botwork/test/goss.yaml`: removed frontdoor service and file assertions.
