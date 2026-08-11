## 1. Phase 0 — Prep

- [x] 1.1 Create a free Doppler account.
- [x] 1.2 Create 5 Doppler projects: `agent-api`, `n8n`, `postgresql`, `redis`,
      `longhorn-backup`. Use the default `prd` config in each; ignore or
      delete `dev`/`stg`.
- [x] 1.3 Populate each project's secrets in `UPPER_SNAKE_CASE` (Doppler's
      native convention — the `lower-kebab` name transformer converts them
      back on the way into the cluster). `DB_PASSWORD`/`REDIS_PASSWORD` are
      deliberately absent from `agent-api`/`n8n` — per Decision #8 they're
      cross-project pulls from `postgresql`/`redis` at Phase 3, not stored
      here:
      - **agent-api**: `DEEPSEEK_API_KEY`, `ANTHROPIC_API_KEY`,
        `OPENAI_API_KEY`, `N8N_SCHEDULE_DELIVERY_SECRET`,
        `GRAPH_CLIENT_SECRET`, `OAUTH_STATE_SECRET`
      - **n8n**: `ENCRYPTION_KEY`
      - **postgresql**: `PASSWORD` — source of truth, also consumed by
        `agent-api` and `n8n`
      - **redis**: `PASSWORD` — source of truth, also consumed by `agent-api`
      - **longhorn-backup**: `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
        `AWS_ENDPOINTS` (already correctly cased, no transform needed)
- [x] 1.4 Pull each real value out of the live cluster to paste into Doppler —
      decodes every key in one shot:
  ```bash
  kubectl get secret agent-api-secrets -n agent-api -o json | jq -r '.data | map_values(@base64d)'
  kubectl get secret n8n-secrets -n n8n -o json | jq -r '.data | map_values(@base64d)'
  kubectl get secret postgresql-credentials -n postgresql -o json | jq -r '.data | map_values(@base64d)'
  kubectl get secret redis-credentials -n redis -o json | jq -r '.data | map_values(@base64d)'
  kubectl get secret longhorn-r2-backup-secret -n longhorn-system -o json | jq -r '.data | map_values(@base64d)'
  ```
- [x] 1.5 Generate one Service Token per project (Doppler dashboard → project
      → config → Access tab) — 5 tokens for 5 projects. Copy each value
      somewhere temporary. The `postgresql` and `redis` tokens get entered
      into the cluster more than once in Phase 2 (once per consumer
      namespace, see Decision #8) — the other 3 tokens are entered once each.
      Nothing is ever stored in git.

## 2. Phase 1 — Install External Secrets Operator

- [x] 2.1 Create `infrastructure/controllers/external-secrets/` mirroring the
      `sealed-secrets/` directory exactly: `namespace.yaml`, `values.yaml`,
      and a `kustomization.yaml` using the `helmCharts` inflator — chart
      `external-secrets` from `https://charts.external-secrets.io`. Pinned
      `2.9.0` (latest chart release as of 2026-08-10). `values.yaml` sets
      small resource requests/limits (50m/64Mi, 100m/128Mi) on all three
      chart-managed Deployments — main controller, `webhook`,
      `certController` — matching the resource-constrained style already
      used in `sealed-secrets/values.yaml`.
- [x] 2.2 Push. No `ApplicationSet` change needed — the existing
      `infrastructure-components-appset.yaml` git-directory generator picks
      up `infrastructure/controllers/*` automatically, same as it already
      does for `sealed-secrets/`. ArgoCD synced clean.
- [x] 2.3 Verify: `kubectl -n external-secrets get pods`. All 3 Deployments
      healthy — `external-secrets` (controller), `external-secrets-webhook`,
      `external-secrets-cert-controller` — all `1/1 Running`, 0 restarts,
      `v2.9.0`.

## 3. Phase 2 — Bootstrap tokens + SecretStores (repeat once per app)

Order matters: do `postgresql` and `redis` first — `agent-api`/`n8n`'s extra
SecretStores need those two projects' tokens to already exist.

- [x] 3.1 Create the bootstrap token Secret manually — not committed to git:
  ```bash
  HISTIGNORE='*kubectl*' kubectl create secret generic doppler-token \
    -n <namespace> --from-literal=dopplerToken="dp.st.xxxx"
  ```
- [x] 3.2 Commit a `secretstore.yaml` per namespace (safe to commit — it only
      references the bootstrap Secret by name, never the token value itself).
      See design.md for the exact shape.
- [x] 3.3 For `agent-api` and `n8n` only — repeat both steps above once per
      shared-credential dependency, reusing the `postgresql`/`redis`
      project's own token value (copied, not regenerated) under a distinct
      Secret name + `SecretStore` name so it doesn't collide with the app's
      own store. See design.md for the exact shape (`doppler-token-postgresql`
      / `doppler-token-redis`, `secretstore-postgresql.yaml` /
      `secretstore-redis.yaml`).

## 4. Phase 3 — Cut over each app (one at a time)

Order: `postgresql`, `redis` first (they're the shared-credential source of
truth), then `agent-api`, `n8n` in either order, then `longhorn-system` last
(it's the one this whole investigation was about — migrate it once the
pattern is proven on the lower-stakes apps).

- [x] 4.1 Add `externalsecret.yaml` for the app's own project (single
      `ExternalSecret` per app — see the post-cutover incident note in
      design.md for why it's consolidated rather than 2-3 separate ones).
- [x] 4.2 Update that app's `kustomization.yaml`: remove `sealedsecret.yaml`,
      add `secretstore.yaml` + `externalsecret.yaml` (+ the extra
      `secretstore-*.yaml` pairs for `agent-api`/`n8n`).
- [x] 4.3 Push, then verify the generated Secret has the same keys and values
      as before:
  ```bash
  kubectl get secret agent-api-secrets -n agent-api -o jsonpath='{.data}' | jq keys
  ```
      and spot-check `db-password`/`redis-password` still decode to the same
      value as `postgresql-credentials`/`redis-credentials`.
- [x] 4.4 Verify the app pod restarts clean and actually works before moving
      to the next app. If something breaks, see the Rollback procedure in
      design.md before touching the next app.

## 5. Phase 4 — Decommission sealed-secrets (intentionally delayed)

Do not rush this. Per Decision #7, sealed-secrets stays installed as a
fallback for an extended soak period after all 5 apps are confirmed working —
there's no fixed calendar trigger, just "confidence is high that Doppler/ESO
is reliable in practice, across real rotations/restarts/node reboots." Once
this phase runs, the Rollback procedure in design.md stops working for good
(the sealed-secrets private key is gone) — treat it as a one-way door.

- [ ] 5.1 Once all 5 apps are migrated, verified, and have run stably on
      Doppler/ESO for an extended period, delete
      `infrastructure/controllers/sealed-secrets/` from git.
- [ ] 5.2 Optionally delete the sealed-secrets key Secrets from the cluster
      (`kubectl -n sealed-secrets delete secret -l sealedsecrets.bitnami.com/sealed-secrets-key`).
- [ ] 5.3 Update repo memory (`/memories/repo/longhorn-backup-dr.md`) — the
      "critical DR gap" note about the sealed-secrets key no longer applies
      once this is done.
