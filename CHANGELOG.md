# Changelog

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
