## Context

See proposal.md - Why. Two devices, one existing platform pattern each:

- **Home Assistant** runs as a plain container Deployment in k3s (`my-apps/home-assistant/`),
  not Home Assistant OS/Supervised — the same constraint noted in
  `add-tesla-solar-charging`'s design.md. HACS is already installed and used in this
  instance (`huawei_solar`), so adding another HACS custom_component is a known-good path,
  not a new capability for this HA install.
- **HA recorder** purges after 10 days (`recorder.purge_keep_days: 10` in
  `my-apps/home-assistant/configuration.yaml`) — any state older than that is gone from HA
  itself. Long-term history for trend analysis must live somewhere else.
- **agent-api** (external repo, `ghcr.io/joan-grau/agent-api`) is a single Deployment
  mounting one shared PVC (`agent-workspace`, 5Gi Longhorn) at `/workspace`, used by every
  agent. Finance Advisor's `watchlist.json` already lives there as a per-agent workspace
  file, managed entirely by agent-api's own "workspace tools" (read/write/list/delete). The
  exact per-agent(-per-user) path convention is implemented in that external repo, not this
  one — confirming it against the live source is implementation-time work, not a decision
  this design needs to make.
- **Finance Advisor** (`agents/platform/agent-api/configmap.yaml` → `agents.yaml`,
  `docs/agent-platform.md` Phase 6) is the direct precedent for adding a domain agent: this
  repo only adds a ConfigMap entry; the LangGraph graph, tools, and Telegram routing all
  live in the external `agent-api` repo. Delivery is dual-channel: Telegram on-demand +
  an n8n cron pushing a scheduled summary.
- **Secrets**: every credential added since `migrate-sealed-secrets-to-doppler` (2026-08-17)
  goes through Doppler + External Secrets Operator — Sealed Secrets is fully retired.
- **Cluster capacity is tight**: single node, ~8GB memory (~82% used), ~98GB disk (~73%
  used) as of the last capacity review — favors low-footprint additions (a CronJob instead
  of an always-on pod, reusing the existing workspace instead of a new stateful service).
- **Devices, confirmed with the user**: Xiaomi **Mi Body Composition Scale 2 (XMTZC05HM)** —
  matches `AlexxIT/SmartScaleConnect`'s tested "Known Scales" table exactly (synced via the
  Zepp Life app, simple impedance). Amazfit **Helio** band — not present in `zepp2hass`'s
  documented supported-device list (which requires installing and confirming a companion
  mini-app directly on the watch's own screen); the user has chosen to attempt it anyway
  rather than descope it up front.

## Goals / Non-Goals

**Goals:**
- Get both devices' data into Home Assistant via each device's best-available, already
  community-maintained integration
- Persist readings beyond HA's 10-day recorder purge, using the same per-agent workspace
  convention Finance Advisor already established — no new database
- Stand up a Health & Fitness domain agent (ConfigMap + n8n + Telegram wiring) that reasons
  over that history and answers questions or pushes a periodic summary
- Keep the added footprint low given the cluster's tight memory/disk headroom

**Non-Goals:**
- Building the agent's LangGraph graph, tools, or prompts — that code lives in the external
  `agent-api` repo, out of scope for this change
- A guaranteed-working Amazfit Helio integration — the `zepp2hass` path is a best-effort
  attempt with an explicit verification step and a scale-only fallback
- Medical-grade analysis or diagnosis — recommendations are wellness/trend-based only
- Real-time sync or live dashboards — twice-daily scale sync and (if working) minute-scale
  band webhook pushes are both eventually-consistent, not live telemetry
- Replacing the Zepp app itself (e.g. Gadgetbridge) — the user asked for read access to the
  data, not to re-pair devices away from their existing apps

## Decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Scale integration | **SmartScaleConnect** (`AlexxIT/SmartScaleConnect`, self-hosted Go app/Docker image), pulling `from: zepp/xiaomi` — matches the Mi Body Composition Scale 2's documented, tested support. Rejected: a custom Zepp-cloud scraper — this is actively maintained (latest release observed Dec 2025) by a reputable HA-ecosystem author (`AlexxIT`, also behind Sonoff LAN / Xiaomi Gateway3 / WebRTC) and already handles this exact scale model |
| 2 | Scale sync runtime | **Kubernetes CronJob**, twice daily — matches the accepted "logs the phone app out" trade-off and keeps steady-state cost near zero between runs. Rejected: a long-running Deployment using SmartScaleConnect's own `-r` self-repeat flag — would keep a pod resident 24/7 for no benefit over a CronJob |
| 3 | Band integration | **zepp2hass** (HACS), attempted despite the Helio not appearing in its documented supported-device list. Treated as a Phase 0 verification spike (does the Zepp Store even offer "zepp2hass" as installable on the paired Helio?) before any automation/ingestion work is built around it. Rejected: **Gadgetbridge** — would mean re-pairing the band away from the official Zepp app (losing Zepp Aura features), a much bigger change than asked for, and no confirmed Helio support was found there either |
| 4 | Local persistence | **JSONL history files in the Health & Fitness agent's existing per-agent workspace** (the `agent-workspace` PVC already mounted in agent-api) — not a new database, per the user's explicit preference to keep this in the same agent-human shared workspace Finance Advisor already uses. Rejected: a new InfluxDB instance (purpose-built, but another stateful service to run/monitor on an already-tight single node); a new PostgreSQL schema (would work, but adds schema/migration surface the workspace file approach avoids entirely) |
| 5 | HA → workspace bridge | HA automation → **n8n webhook workflow** → a new **agent-api HTTP endpoint** (pattern-matched to the existing `/admin/memory/*` admin endpoints) that appends to the workspace file. Rejected: n8n writing directly to the workspace PVC — n8n doesn't mount `agent-workspace` today, and routing everything through agent-api keeps a single code path owning the file format, avoiding two writers racing on the same file |
| 6 | Health agent registration | `agents/platform/agent-api/configmap.yaml` → `agents.yaml`, `memory: true`, following Finance Advisor's entry shape exactly (`name`/`description`/`graph`/`default_tier`/`memory`) |
| 7 | Delivery channels | Both **Telegram on-demand** queries (health-intent routing added to the existing router, same as Finance) and a **scheduled weekly** summary via n8n cron → `/agents/health/invoke` → Telegram. Weekly rather than Finance's daily cadence — health/fitness trends move meaningfully slower than market data |
| 8 | Credentials | Zepp/Xiaomi account username + password for SmartScaleConnect via **Doppler + External Secrets Operator** — the only pattern used for any new secret since Sealed Secrets was retired |

## Risks / Trade-offs

> **`zepp2hass` may simply not work on the Helio** — it has no screen to run or confirm the
> on-watch mini-app on, and the device isn't in the integration's documented supported list.
> → Mitigation: Phase 0 verification step before building anything else band-related. If it
> doesn't work, band ingestion is dropped and this change ships scale-only — still delivers
> the core goal (body-composition trend analysis); band metrics become a future change if a
> working path ever appears.

> **SmartScaleConnect's Zepp Life sync path logs the user out of the Zepp mobile app on
> every run.** → Mitigation: explicitly accepted by the user, mitigated by syncing only
> twice daily rather than continuously.

> **SmartScaleConnect describes itself as "at an early stage of development... configuration
> and functionality can change a lot."** → Mitigation: pin a specific released image
> tag/version rather than `latest`; treat config drift as normal maintenance, not a one-time
> setup.

> **Unbounded JSONL growth in the shared workspace over years of daily readings.** →
> Mitigation: individual readings are a few hundred bytes each — a non-issue at realistic
> homelab timescales. Worth a lightweight periodic compaction/rotation job later (same
> spirit as the existing Mem0 memory-lifecycle jobs) if it ever actually becomes one — not
> built now, there's no evidence it's needed yet.

> **Two writers racing on the same workspace file.** → Mitigation: Decision 5 routes every
> write through the single agent-api process — a normal single-writer append, no
> distributed locking required.

> **A new public attack surface, like the Tesla change's `cloudflared` ingress rule.** →
> Not applicable here: HA's `/api/webhook/<id>` mechanism used for the scale (and,
> if applicable, `zepp2hass`) is internal/LAN-only — no new public ingress rule, no
> `cloudflared` config change at all.

## Migration Plan

1. **Phase 0 (verification)**: pair the Helio in the Zepp app, open the Zepp Store on the
   phone, and search for "zepp2hass" — confirm whether it's installable at all on this
   device before doing anything else band-related.
2. Deploy `my-apps/smartscale-connect/` (namespace, ExternalSecret sourcing Zepp/Xiaomi
   credentials from Doppler, CronJob running twice daily, kustomization) — Argo CD picks it
   up automatically, no ApplicationSet change needed.
3. Add an HA webhook + automation to receive SmartScaleConnect's pushed readings (native HA
   entities for the scale, same as every other integration in this instance).
4. If Phase 0 confirmed feasibility: install `zepp2hass` via HACS, add the webhook
   integration entry, install/configure the mini-app on the watch, verify sensors appear.
5. Build the HA → n8n → agent-api ingestion bridge (new agent-api endpoint, new n8n
   workflow) and confirm readings land in the workspace JSONL file(s).
6. Register the `health` agent in `agents/platform/agent-api/configmap.yaml`; the
   agent-api implementation (graph/tools) happens in that external repo, out of scope here.
7. Wire Telegram health-intent routing and the weekly n8n summary cron.
8. Verify end-to-end: a new scale weighing (and, if applicable, a band sync) shows up in HA,
   then in the workspace file, then is reflected in an agent response within one cycle.

**Rollback:** nothing here is destructive to existing systems. To abort: remove the HA
integrations/automations, `rm -rf my-apps/smartscale-connect`, drop the `health` entry from
agent-api's ConfigMap, and delete the n8n workflow(s). None of this touches
`assistant`/`finance`/`ecommerce` or any other existing app.

## Open Questions

1. Exact workspace file path/naming convention for a new agent (e.g. whether it's
   `/workspace/<agent_id>/<user_id>/...` or something else) — needs confirming against the
   live `agent-api` source during implementation, the same way `add-tesla-solar-charging`
   deferred exact HA entity IDs to implementation time rather than guessing them here.
2. Whether the Helio's `zepp2hass` mini-app, if installable at all, exposes the same full
   sensor set as screen-equipped devices or a reduced subset (it's a health-focused,
   screen-less strap) — only observable once Phase 0/4 actually runs.
3. Exact new agent-api ingestion endpoint path/auth (e.g. token-protected like the
   `/admin/memory/*` endpoints) — an `agent-api`-repo implementation detail, not something
   this repo's change needs to resolve now.
