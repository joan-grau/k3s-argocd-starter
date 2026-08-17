## Context

Sealed Secrets encrypts credentials so they're safe to commit to git, but
decryption depends on a private key that only exists inside the cluster and
auto-rotates. That key has no external backup by design — see
`/memories/repo/longhorn-backup-dr.md` for the disaster-recovery gap this
creates for the Longhorn R2 backup credential specifically. External Secrets
Operator (ESO) + Doppler replaces "a key you must keep alive and backed up"
with "a token you can regenerate any time from a dashboard", at the cost of a
dependency on an external service.

## Goals / Non-Goals

**Goals:**
- Every current `SealedSecret`'s keys and values survive the migration
  unchanged from the consuming application's point of view (same k8s `Secret`
  name, same keys, same values)
- Shared credentials (Postgres/Redis passwords) are deduplicated instead of
  copy-pasted across Doppler projects
- A working rollback path exists for each app until sealed-secrets is actually
  removed
- Nothing sensitive (tokens, passwords) is ever committed to git

**Non-Goals:**
- Removing sealed-secrets immediately after cutover — Phase 4 is deliberately
  delayed until confidence is high (see Decision #7)
- A multi-environment Doppler setup (`dev`/`stg` configs are ignored/deleted;
  single `prd` config per project)

## Decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Backend | **Doppler**, free tier |
| 2 | Doppler structure | **5 separate Doppler projects**, one per current `SealedSecret` (`agent-api`, `n8n`, `postgresql`, `redis`, `longhorn-backup`), single `prd` config each. Avoids key-name collisions (`db-password` is used by both agent-api and n8n; `password` by both postgresql and redis) and preserves today's per-namespace isolation |
| 3 | `SecretStore` scope | Namespace-scoped `SecretStore`, not a cluster-wide `ClusterSecretStore` — same isolation boundary as today's per-namespace sealing |
| 4 | Key naming | Doppler secrets are named in its native `UPPER_SNAKE_CASE`. Each app's **own** `SecretStore` (the one whose `ExternalSecret` uses `dataFrom.find` to fetch everything) sets `nameTransformer: lower-kebab` so the resulting k8s `Secret` keeps today's exact `lower-kebab` keys — **zero Deployment changes**. Exceptions: the `longhorn` store has no transformer (keys already uppercase `AWS_ACCESS_KEY_ID` etc., must stay that way), and the cross-project shared-credential stores (`doppler-postgresql`, `doppler-redis`, see #8) also have no transformer — they cherry-pick one explicit key instead |
| 5 | Fetch style | `dataFrom` with `find.name.regexp: ".*"` for each project's *own* keys (self-maintaining if a key is ever added/removed in Doppler). For the two cross-project shared-password pulls (see #8), an explicit `data:` entry with `remoteRef.key: PASSWORD` is used instead, since only one specific key is cherry-picked and renamed (`PASSWORD` → `db-password`/`redis-password`) |
| 6 | Bootstrap token distribution | One Doppler **Service Token** per project, manually created as a `kubectl create secret` per namespace — **never committed to git**. The `postgresql` and `redis` tokens are each created in **more than one namespace** (own namespace + every consumer namespace, see #8) — same token value, one extra `kubectl create secret` run per consumer. Lower-stakes than the old sealed-secrets key: if lost, just regenerate a fresh token from the Doppler dashboard, no data loss |
| 7 | Rollout style | Migrate and verify **one app at a time**, keep sealed-secrets installed as a long-running safety net. **Phase 4 (decommission) is deliberately delayed** — not run right after the 5th app is confirmed working. Doppler/ESO is new tooling for this cluster, so sealed-secrets stays installed for an extended soak period until confidence is high. **Order matters now**: `postgresql` and `redis` first (source of truth for #8), then `agent-api`/`n8n` (depend on those two projects' tokens existing), then `longhorn-system` last. See the Rollback procedure below for how to revert a single app mid-migration |
| 8 | Shared credentials (Postgres/Redis password) | **Deduplicated.** Confirmed live in-cluster that `agent-api`'s `db-password`, `n8n`'s `db-password`, and `postgresql`'s `password` are byte-identical (same for `agent-api`'s `redis-password` vs `redis`'s `password`). `postgresql`/`redis` are now the **sole source of truth**; `agent-api`/`n8n` no longer store their own copy in Doppler — their **single** `ExternalSecret` pulls it cross-project via an extra `SecretStore` plus a per-item `sourceRef.storeRef` override (`creationPolicy: CreateOrMerge`) instead. Rotate the password once in `postgresql`/`redis`, every consumer picks it up on its next `refreshInterval` — no more manual multi-project sync. *(Originally implemented as two/three separate `ExternalSecret`s per app targeting the same `Secret` — consolidated into one on 2026-08-11 after this caused a real n8n outage, see the incident note below.)* |

### Secrets inventory

Confirmed live in-cluster (2026-08-10) that `agent-api-secrets.db-password` ==
`postgresql-credentials.password`, `n8n-secrets.db-password` ==
`postgresql-credentials.password`, and `agent-api-secrets.redis-password` ==
`redis-credentials.password` — byte-identical, not just similarly named. Per
Decision #8, `postgresql` and `redis` are the sole source of truth for these
two values going forward; `agent-api` and `n8n` pull them cross-project
instead of storing their own copy.

| Namespace | Current `SealedSecret` | Keys | Sourced from Doppler project |
|---|---|---|---|
| `agent-api` | `agent-api-secrets` | `deepseek-api-key`, `anthropic-api-key`, `openai-api-key`, `n8n-schedule-delivery-secret`, `graph-client-secret`, `oauth-state-secret` | `agent-api` (own) |
| `agent-api` | `agent-api-secrets` | `db-password` *(cross-project pull, not stored in `agent-api` project)* | `postgresql` |
| `agent-api` | `agent-api-secrets` | `redis-password` *(cross-project pull, not stored in `agent-api` project)* | `redis` |
| `n8n` | `n8n-secrets` | `encryption-key` | `n8n` (own) |
| `n8n` | `n8n-secrets` | `db-password` *(cross-project pull, not stored in `n8n` project)* | `postgresql` |
| `postgresql` | `postgresql-credentials` | `password` — **source of truth**, also feeds `agent-api`'s and `n8n`'s `db-password` | `postgresql` |
| `redis` | `redis-credentials` | `password` — **source of truth**, also feeds `agent-api`'s `redis-password` | `redis` |
| `longhorn-system` | `longhorn-r2-backup-secret` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINTS` | `longhorn-backup` |

5 k8s `Secret`s, 15 total keys across them — but only **12 unique values
actually stored in Doppler** (3 fewer than a naive 1:1 mirror), since
`db-password` and `redis-password` are cross-project references rather than
separate copies.

### SecretStore / ExternalSecret shape

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: doppler
  namespace: agent-api
spec:
  provider:
    doppler:
      auth:
        secretRef:
          dopplerToken:
            name: doppler-token
            key: dopplerToken
      nameTransformer: lower-kebab   # omit this line for longhorn-system only
```

For `agent-api` and `n8n`, an extra `SecretStore` per shared-credential
dependency, reusing the `postgresql`/`redis` project's own token value (copied,
not regenerated) under a distinct Secret name so it doesn't collide with the
app's own store:

```yaml
# secretstore-postgresql.yaml — namespace: agent-api (and, separately, namespace: n8n)
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: doppler-postgresql
  namespace: agent-api
spec:
  provider:
    doppler:
      auth:
        secretRef:
          dopplerToken:
            name: doppler-token-postgresql
            key: dopplerToken
      # no nameTransformer: the ExternalSecret cherry-picks PASSWORD explicitly
```

(`secretstore-redis.yaml` in `agent-api` only, same shape, named
`doppler-redis`.)

The consuming `ExternalSecret` (one per app, since the incident below):

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: agent-api-secrets
  namespace: agent-api
spec:
  secretStoreRef:
    name: doppler
    kind: SecretStore
  target:
    name: agent-api-secrets
    creationPolicy: CreateOrMerge   # agent-api/n8n only: self-heals if the Secret is ever deleted
  refreshInterval: 1h
  dataFrom:
    - find:
        name:
          regexp: ".*"
  data:
    - secretKey: db-password
      remoteRef:
        key: PASSWORD
      sourceRef:
        storeRef:
          name: doppler-postgresql
          kind: SecretStore
    - secretKey: redis-password
      remoteRef:
        key: PASSWORD
      sourceRef:
        storeRef:
          name: doppler-redis
          kind: SecretStore
```

`n8n` has only the `db-password` entry, pointing at `doppler-postgresql` — no
Redis dependency. `postgresql`, `redis`, `longhorn-system` don't need
`creationPolicy: CreateOrMerge` or any `data` override — only one
`ExternalSecret` ever targets their Secret and there's no cross-project pull,
so the default `Owner` policy is fine.

**Why `CreateOrMerge`, not plain `Merge`** (checked against ESO's
ownership/deletion docs on 2026-08-10, before implementing this for
`agent-api`/`n8n`): `Merge` never sets `.metadata.ownerReferences`, and per
ESO's own behavior matrix it "never creates" the Secret if it's missing. At
that point in the migration, `agent-api-secrets`/`n8n-secrets` were still
owned by their `SealedSecret`; removing `sealedsecret.yaml` prunes that CR, and
we'd already watched this exact scenario cascade-delete
`postgresql-credentials`/`redis-credentials` via Kubernetes garbage collection
during their own cutover. With plain `Merge`, that deletion would have been
permanent — no `ExternalSecret` would ever recreate it. `CreateOrMerge` keeps
the same "coexist, don't fight over keys" behavior but recreates the Secret
immediately if it's ever missing, closing that gap.

## Risks / Trade-offs

### Post-cutover incident (2026-08-11): CreateOrMerge race, real n8n outage

After all 5 apps restarted to pick up fresh Doppler values, `n8n` went into
`CrashLoopBackOff` (`password authentication failed for user "agents"`). Root
cause: a leftover `DB_PASSWORD`-shaped key still existed in n8n's own Doppler
project (it should only ever contain `ENCRYPTION_KEY`). At the time, n8n had
**two** `ExternalSecret`s writing into the same `Secret` under
`creationPolicy: CreateOrMerge` — the wildcard one (n8n's own project) and the
cross-project one (`postgresql`'s project) — and whichever reconciled most
recently was overwriting `db-password`.

Deleting the leftover key made it **worse**, not better: `db-password`
disappeared entirely from the Secret (`CreateContainerConfigError`), because
the wildcard `ExternalSecret` reconciled (no longer producing that field)
while the cross-project one hadn't reconciled in hours, so nothing re-claimed
it. This proved `CreateOrMerge` across two `ExternalSecret`s targeting the
same `Secret` is not a stable merge — the most-recently-reconciled object's
field set always wins, silently deleting anything it doesn't currently
produce, even fields a sibling `ExternalSecret` owns. This could have
recurred on any future `refreshInterval` cycle, not just at cutover.

**Fix**: consolidated each app's `ExternalSecret`s into one, using ESO v1's
`data[].sourceRef.storeRef` (confirmed present in the installed v2.9.0 CRD) to
override the store for just the cherry-picked key(s) while the rest come from
the default `secretStoreRef` via the wildcard `dataFrom`. One `ExternalSecret`
per app now means one reconcile loop and one atomic write of the full key set
— structurally impossible for this race to happen again. Applied to both
`agent-api` and `n8n` (agent-api hadn't hit the bug yet, but had the identical
multi-`ExternalSecret` structure). See the `ExternalSecret` shape above and
Decision #8.

### Rollback procedure (per app, only works before Phase 4 runs)

If an app's cutover causes problems, revert just that app back to its
`SealedSecret` — safe as long as Phase 4 hasn't run yet (controller still
installed, private key still valid):

1. `git revert` (or manually undo) that app's cutover commit: restores
   `sealedsecret.yaml` to the `kustomization.yaml` `resources:` list and
   removes `secretstore.yaml` / `externalsecret.yaml` (+ the extra
   `secretstore-*.yaml` pairs for `agent-api`/`n8n` — the cross-project store
   references live inside the single `externalsecret.yaml` since 2026-08-11,
   not separate `externalsecret-*.yaml` files).
2. Push and let ArgoCD sync. What happens next differs by `creationPolicy`:
   - `postgresql`, `redis`, `longhorn-system` (own `ExternalSecret` uses the
     default `Owner` policy): pruning it **deletes** the Secret it owned —
     expect a brief gap until the reinstated `SealedSecret` CR reconciles and
     the sealed-secrets controller recreates it, during which the app pod may
     restart/error momentarily.
   - `agent-api`, `n8n` (their single `ExternalSecret` uses `CreateOrMerge`):
     pruning it does **not** delete the Secret — it's left with whatever ESO
     last wrote. The sealed-secrets controller then takes over that
     same-named Secret once the `SealedSecret` CR is reinstated, so the gap
     should be smaller or nonexistent.
3. Verify: `kubectl get secret <name> -n <namespace> -o jsonpath='{.data}' | jq keys`
   shows the original keys again, and the app pod restarts clean.
4. Optional cleanup: delete the now-unused Doppler bootstrap token Secret(s)
   (`doppler-token`, `doppler-token-postgresql`, `doppler-token-redis`) in
   that namespace — harmless if left, ESO just has nothing left to reconcile
   against.

**Not yet tested live** — this rollback direction (reinstating `SealedSecret`
after removing `ExternalSecret`) is inferred from how each operator documents
its `creationPolicy`/ownership behavior, not verified end-to-end in this
cluster. Consider rehearsing this once on a low-stakes app (e.g. `n8n`) before
relying on it as a real safety net. The *forward* cutover direction
(`SealedSecret` → `ExternalSecret`) was checked against ESO's docs before
implementing `agent-api`/`n8n` — see the `CreateOrMerge` note above.
