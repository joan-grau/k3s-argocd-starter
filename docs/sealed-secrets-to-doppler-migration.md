# Sealed Secrets → External Secrets Operator (Doppler) Migration

> **Status**: Planning — nothing implemented yet. Started 2026-08-10.

## Why

The sealed-secrets controller's private key lives only inside the cluster and rotates
every ~30 days. If the homelab server is lost entirely, every `SealedSecret` in this
repo — including the Longhorn R2 backup credential — becomes permanently
undecryptable, even though the backed-up data itself is safe. Moving secret storage to
Doppler (an external, cloud-hosted service) means a full cluster rebuild only needs one
thing to recover everything: a fresh Doppler Service Token per app, generated from the
Doppler dashboard. No private key file to back up and keep current.

---

## Decisions taken

| # | Decision | Choice |
|---|----------|--------|
| 1 | Backend | **Doppler**, free tier |
| 2 | Doppler structure | **5 separate Doppler projects**, one per current `SealedSecret` (`agent-api`, `n8n`, `postgresql`, `redis`, `longhorn-backup`), single `prd` config each. Avoids key-name collisions (`db-password` is used by both agent-api and n8n; `password` by both postgresql and redis) and preserves today's per-namespace isolation |
| 3 | `SecretStore` scope | Namespace-scoped `SecretStore`, not a cluster-wide `ClusterSecretStore` — same isolation boundary as today's per-namespace sealing |
| 4 | Key naming | Doppler secrets are named in its native `UPPER_SNAKE_CASE`. Each app's **own** `SecretStore` (the one whose `ExternalSecret` uses `dataFrom.find` to fetch everything) sets `nameTransformer: lower-kebab` so the resulting k8s `Secret` keeps today's exact `lower-kebab` keys — **zero Deployment changes**. Exceptions: the `longhorn` store has no transformer (keys already uppercase `AWS_ACCESS_KEY_ID` etc., must stay that way), and the cross-project shared-credential stores (`doppler-postgresql`, `doppler-redis`, see #8) also have no transformer — they cherry-pick one explicit key instead |
| 5 | Fetch style | `dataFrom` with `find.name.regexp: ".*"` for each project's *own* keys (self-maintaining if a key is ever added/removed in Doppler). For the two cross-project shared-password pulls (see #8), an explicit `data:` entry with `remoteRef.key: PASSWORD` is used instead, since only one specific key is cherry-picked and renamed (`PASSWORD` → `db-password`/`redis-password`) |
| 6 | Bootstrap token distribution | One Doppler **Service Token** per project, manually created as a `kubectl create secret` per namespace — **never committed to git**. The `postgresql` and `redis` tokens are each created in **more than one namespace** (own namespace + every consumer namespace, see #8) — same token value, one extra `kubectl create secret` run per consumer. Lower-stakes than the old sealed-secrets key: if lost, just regenerate a fresh token from the Doppler dashboard, no data loss |
| 7 | Rollout style | Migrate and verify **one app at a time**, keep sealed-secrets installed as a safety net until all 5 are confirmed working, decommission it last. **Order matters now**: `postgresql` and `redis` first (source of truth for #8), then `agent-api`/`n8n` (depend on those two projects' tokens existing), then `longhorn-system` last |
| 8 | Shared credentials (Postgres/Redis password) | **Deduplicated.** Confirmed live in-cluster that `agent-api`'s `db-password`, `n8n`'s `db-password`, and `postgresql`'s `password` are byte-identical (same for `agent-api`'s `redis-password` vs `redis`'s `password`). `postgresql`/`redis` are now the **sole source of truth**; `agent-api`/`n8n` no longer store their own copy in Doppler — their `ExternalSecret`s pull it cross-project via an extra `SecretStore` + `ExternalSecret` (`creationPolicy: Merge`) instead. Rotate the password once in `postgresql`/`redis`, every consumer picks it up on its next `refreshInterval` — no more manual multi-project sync |

---

## Secrets inventory

Confirmed live in-cluster (2026-08-10) that `agent-api-secrets.db-password` ==
`postgresql-credentials.password`, `n8n-secrets.db-password` ==
`postgresql-credentials.password`, and `agent-api-secrets.redis-password` ==
`redis-credentials.password` — byte-identical, not just similarly named. Per
Decision #8, `postgresql` and `redis` are the sole source of truth for these two
values going forward; `agent-api` and `n8n` pull them cross-project instead of
storing their own copy.

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

5 k8s `Secret`s, 15 total keys across them — but only **12 unique values actually
stored in Doppler** (3 fewer than a naive 1:1 mirror), since `db-password` and
`redis-password` are cross-project references rather than separate copies.

---

## What is missing

### Phase 0 — Prep

- [ ] Create a free Doppler account.
- [ ] Create 5 Doppler projects: `agent-api`, `n8n`, `postgresql`, `redis`,
      `longhorn-backup`. Use the default `prd` config in each; ignore or delete
      `dev`/`stg`.
- [ ] Populate each project's secrets in `UPPER_SNAKE_CASE` (Doppler's native
      convention — the `lower-kebab` name transformer converts them back on the way
      into the cluster). **`DB_PASSWORD`/`REDIS_PASSWORD` are deliberately absent
      from `agent-api`/`n8n` below** — per Decision #8 they're cross-project pulls
      from `postgresql`/`redis` at Phase 3, not stored here:
  - **agent-api**: `DEEPSEEK_API_KEY`, `ANTHROPIC_API_KEY`,
        `OPENAI_API_KEY`, `N8N_SCHEDULE_DELIVERY_SECRET`,
        `GRAPH_CLIENT_SECRET`, `OAUTH_STATE_SECRET`
  - **n8n**: `ENCRYPTION_KEY`
  - **postgresql**: `PASSWORD` — source of truth, also consumed by `agent-api` and `n8n`
  - **redis**: `PASSWORD` — source of truth, also consumed by `agent-api`
  - **longhorn-backup**: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINTS`
        (already correctly cased, no transform needed)
- [ ] Pull each real value out of the live cluster to paste into Doppler — decodes
      every key in one shot:
  ```bash
  kubectl get secret agent-api-secrets -n agent-api -o json | jq -r '.data | map_values(@base64d)'
  kubectl get secret n8n-secrets -n n8n -o json | jq -r '.data | map_values(@base64d)'
  kubectl get secret postgresql-credentials -n postgresql -o json | jq -r '.data | map_values(@base64d)'
  kubectl get secret redis-credentials -n redis -o json | jq -r '.data | map_values(@base64d)'
  kubectl get secret longhorn-r2-backup-secret -n longhorn-system -o json | jq -r '.data | map_values(@base64d)'
  ```
- [ ] Generate one **Service Token** per project (Doppler dashboard → project →
      config → Access tab) — 5 tokens for 5 projects. Copy each value somewhere
      temporary. The `postgresql` and `redis` tokens get entered into the cluster
      **more than once** in Phase 2 (once per consumer namespace, see #8) — the
      other 3 tokens are entered once each. Nothing is ever stored in git.

### Phase 1 — Install External Secrets Operator

- [ ] Create `infrastructure/controllers/external-secrets/` mirroring the
      `sealed-secrets/` directory exactly: `namespace.yaml`, `values.yaml`, and a
      `kustomization.yaml` using the `helmCharts` inflator —
      chart `external-secrets` from `https://charts.external-secrets.io`
      (check [the release list](https://github.com/external-secrets/external-secrets/releases)
      for the current version before pinning it).
- [ ] Push. No `ApplicationSet` change needed — the existing
      [`infrastructure-components-appset.yaml`](../infrastructure/infrastructure-components-appset.yaml)
      git-directory generator picks up `infrastructure/controllers/*` automatically,
      same as it already does for `sealed-secrets/`.
- [ ] Verify: `kubectl -n external-secrets get pods`.

### Phase 2 — Bootstrap tokens + SecretStores (repeat once per app)

**Order matters**: do `postgresql` and `redis` first — `agent-api`/`n8n`'s extra
SecretStores below need those two projects' tokens to already exist.

- [ ] Create the bootstrap token Secret manually — **not committed to git**:
  ```bash
  HISTIGNORE='*kubectl*' kubectl create secret generic doppler-token \
    -n <namespace> --from-literal=dopplerToken="dp.st.xxxx"
  ```
- [ ] Commit a `secretstore.yaml` per namespace (safe to commit — it only
      references the bootstrap Secret by name, never the token value itself):
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
- [ ] For `agent-api` and `n8n` only — repeat both steps above **once per
      shared-credential dependency**, reusing the `postgresql`/`redis` project's
      own token value (copied, not regenerated) under a distinct Secret name +
      `SecretStore` name so it doesn't collide with the app's own store:
  ```bash
  # in the agent-api namespace
  HISTIGNORE='*kubectl*' kubectl create secret generic doppler-token-postgresql \
    -n agent-api --from-literal=dopplerToken="<same token as postgresql's own doppler-token>"
  HISTIGNORE='*kubectl*' kubectl create secret generic doppler-token-redis \
    -n agent-api --from-literal=dopplerToken="<same token as redis's own doppler-token>"
  ```
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
        # no nameTransformer: the ExternalSecret cherry-picks PASSWORD explicitly (Phase 3)
  ```
  (`secretstore-redis.yaml` in `agent-api` only, same shape, named `doppler-redis`)

### Phase 3 — Cut over each app (one at a time)

Order: `postgresql`, `redis` first (they're the shared-credential source of
truth), then `agent-api`, `n8n` in either order, then `longhorn-system` last
(it's the one this whole investigation was about — migrate it once the pattern is
proven on the lower-stakes apps).

- [ ] Add `externalsecret.yaml` for the app's own project, e.g. for agent-api:
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
      creationPolicy: Merge   # agent-api/n8n only: lets the cross-project ExternalSecrets below merge into the same Secret
    refreshInterval: 1h
    dataFrom:
      - find:
          name:
            regexp: ".*"
  ```
  (`postgresql`, `redis`, `longhorn-system` don't need `creationPolicy: Merge` —
  only one `ExternalSecret` ever targets their Secret, so the default `Owner`
  policy is fine.)
- [ ] For `agent-api` and `n8n` only — add one more `ExternalSecret` per
      shared-credential dependency, cherry-picking just the one key:
  ```yaml
  # externalsecret-postgresql.yaml — namespace: agent-api (and, separately, namespace: n8n)
  apiVersion: external-secrets.io/v1
  kind: ExternalSecret
  metadata:
    name: agent-api-secrets-db-password
    namespace: agent-api
  spec:
    secretStoreRef:
      name: doppler-postgresql
      kind: SecretStore
    target:
      name: agent-api-secrets
      creationPolicy: Merge
    refreshInterval: 1h
    data:
      - secretKey: db-password
        remoteRef:
          key: PASSWORD
  ```
  (`externalsecret-redis.yaml` in `agent-api` only, same shape, `secretKey: redis-password`,
  `secretStoreRef.name: doppler-redis`. In `n8n`, `secretKey` stays `db-password`
  since that's `n8n-secrets`' existing key name.)
- [ ] Update that app's `kustomization.yaml`: remove `sealedsecret.yaml`, add
      `secretstore.yaml` + `externalsecret.yaml` (+ the extra `secretstore-*.yaml` /
      `externalsecret-*.yaml` pairs for `agent-api`/`n8n`).
- [ ] Push, then verify the generated Secret has the **same keys and values** as
      before: `kubectl get secret agent-api-secrets -n agent-api -o jsonpath='{.data}' | jq keys`,
      and spot-check `db-password`/`redis-password` still decode to the same value
      as `postgresql-credentials`/`redis-credentials`.
- [ ] Verify the app pod restarts clean and actually works before moving to the next app.

### Phase 4 — Decommission sealed-secrets

- [ ] Once all 5 apps are migrated and verified, delete
      `infrastructure/controllers/sealed-secrets/` from git.
- [ ] Optionally delete the sealed-secrets key Secrets from the cluster
      (`kubectl -n sealed-secrets delete secret -l sealedsecrets.bitnami.com/sealed-secrets-key`).
- [ ] Update [repo memory](/memories/repo/longhorn-backup-dr.md) — the "critical DR
      gap" note about the sealed-secrets key no longer applies once this is done.
