## Why

The sealed-secrets controller's private key lives only inside the cluster and
rotates every ~30 days. If the homelab server is lost entirely, every
`SealedSecret` in this repo — including the Longhorn R2 backup credential —
becomes permanently undecryptable, even though the backed-up data itself is
safe. Moving secret storage to Doppler (an external, cloud-hosted service)
means a full cluster rebuild only needs one thing to recover everything: a
fresh Doppler Service Token per app, generated from the Doppler dashboard. No
private key file to back up and keep current.

## What Changes

- Install External Secrets Operator (ESO) alongside the existing
  sealed-secrets controller (both run during the migration)
- Create 5 Doppler projects — one per current `SealedSecret`: `agent-api`,
  `n8n`, `postgresql`, `redis`, `longhorn-backup`
- Migrate each app, one at a time, from a committed `SealedSecret` to a
  namespace-scoped `SecretStore` + `ExternalSecret` pulling from its Doppler
  project
- Deduplicate the shared Postgres/Redis passwords: `postgresql` and `redis`
  become the sole source of truth, with `agent-api`/`n8n` pulling those two
  keys cross-project via `sourceRef.storeRef` instead of storing their own
  copy
- Keep sealed-secrets installed as a fallback for an extended soak period
  after all 5 apps are migrated (Phase 4 decommission is deliberately
  delayed — see design.md Decision #7)

## Capabilities

### New Capabilities

None. This is a secrets-backend migration for a personal homelab cluster — it
changes which system stores and injects credentials, not a documented external
behavior contract tracked as an OpenSpec capability in this repo.
`skip_specs: true` is set in `.openspec.yaml`.

### Modified Capabilities

None.

## Impact

- **Added**: `infrastructure/controllers/external-secrets/` (new Argo
  CD-managed controller, picked up automatically by the existing
  `infrastructure-components-appset.yaml` git-directory generator)
- **Changed per app** (`agent-api`, `n8n`, `postgresql`, `redis`,
  `longhorn-system`): `kustomization.yaml` swaps `sealedsecret.yaml` for
  `secretstore.yaml` + `externalsecret.yaml` (plus extra cross-project
  `secretstore-*.yaml` files for `agent-api`/`n8n`)
- **Manual, never committed**: one Doppler Service Token bootstrap Secret per
  namespace (`kubectl create secret`), created outside git
- **Removed (Phase 4, delayed)**: `infrastructure/controllers/sealed-secrets/`
  and the sealed-secrets key Secrets, once confidence in Doppler/ESO is high
- **Repo memory**: `/memories/repo/longhorn-backup-dr.md` — the "critical DR
  gap" note about the sealed-secrets key no longer applies once Phase 4
  completes
