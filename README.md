# vm staging tree

This directory stages the files that will be extracted into a separate VM-build repository (for example `botspace-vm`).

For now these files are duplicates of the authoritative files at the repository root. Keep the root copies authoritative until the extraction PR lands.

## Scope

This tree is for the base-build flow only:

- `./vm/scripts/pack.sh` runs the Packer validate/build flow against `vm/images/`
- `./vm/scripts/test-packed.sh` smoke-tests the built image from `build/`
- `./vm/scripts/test-packed.sh --with-payload` consumes a prebuilt `build/botspace-payload.iso`

Payload/deploy assets still live at the repository root (`deploy/`, payload Envoy config, and payload build scripts).

## Typical flow

```bash
./vm/scripts/pack.sh
./vm/scripts/test-packed.sh

# optional payload smoke path
./scripts/build-payload.sh
./vm/scripts/test-packed.sh --with-payload
```

Both the root scripts and the staged `vm/` scripts share the repository-root `build/` output directory during this transition.

## Base-stack security model (no-auth)

- This `vm/` base stack has **no authentication and no tenant isolation**. It
  runs one fixed server-set tenant: `mcp`.
- Do **not** expose this base stack directly to untrusted networks as-is. Path
  plumbing under `/<tenant>/<plugin>` is single-tenant here despite looking
  multi-tenant.
- Auth/vault is added by a separate private overlay composition; this staging
  tree intentionally omits that overlay, including the auth-broker unit and any
  vault directory creation.
- The auth seam is a fixed ECDS slot in `vm/envoy/lds/listener.yaml`:
  `envoy.filters.http.ext_authz` is pinned before `envoy.filters.http.lua`.
  Base ships a benign default at `vm/envoy/ecds/ext_authz.yaml` that keeps the
  filter disabled (`filter_enabled.default_value.numerator: 0`), so the base starts and serves with
  no authn/z while still preserving the seam contract.

## Envoy file-based xDS layout

The base Envoy config is split into an immutable bootstrap plus filesystem xDS
files mounted into `/etc/envoy/...`:

```text
vm/envoy/envoy.yaml          # bootstrap: admin + filesystem LDS/CDS pointers
vm/envoy/lds/listener.yaml   # listener + HTTP filter chain + routes
vm/envoy/cds/clusters.yaml   # base clusters (no auth_broker)
vm/envoy/ecds/ext_authz.yaml # base default for ext_authz seam
```

`vm/envoy/envoy.yaml` must stay overlay-agnostic: no inline ext_authz filter
config and no `auth_broker` cluster.

Base systemd units for this no-auth stack live under `vm/systemd/`. The
private overlay supplies any auth-broker-specific unit wiring separately.

## Overlay file/path contract (private overlay)

The private auth/vault overlay must only swap files over these fixed paths:

- `/etc/envoy/ecds/ext_authz.yaml` (container path; host source is mounted from `/etc/botwork/envoy/ecds/`)  
  Replace base default with real `envoy.filters.http.ext_authz` config that
  sets trusted `x-botwork-tenant` from vault-unlock-derived identity.
- `/etc/envoy/cds/clusters.yaml` (container path; host source is mounted from `/etc/botwork/envoy/cds/`)  
  Replace/extend base clusters with overlay `auth_broker` STRICT_DNS cluster.

Contract details that must not drift:

- Filter name: `envoy.filters.http.ext_authz`
- Fixed filter position: before `envoy.filters.http.lua`
- ECDS file path: `/etc/envoy/ecds/ext_authz.yaml`
- ECDS `type_urls`: `type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz`
- CDS file path: `/etc/envoy/cds/clusters.yaml`

The overlay must never edit `vm/envoy/envoy.yaml`.
