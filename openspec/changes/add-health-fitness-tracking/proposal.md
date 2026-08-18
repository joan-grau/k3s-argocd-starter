## Why

The Amazfit Helio band and the Xiaomi Mi Body Composition Scale 2 both currently funnel
through the Zepp app to Zepp's cloud, with no local record and nothing that reasons over
trends. Home Assistant is already this homelab's single hub for every other device
(`migrate-homebridge-to-home-assistant`), but neither device is connected to it today, and
HA's own recorder purges after 10 days (`purge_keep_days: 10`) — too short for any
meaningful health/fitness trend analysis even once ingested. This change brings both
devices' data into Home Assistant, persists it beyond the recorder's purge window, and adds
a domain agent (following the existing Finance Advisor pattern) that reads the history to
identify tendencies and give recommendations.

## What Changes

- Add the Xiaomi Mi Body Composition Scale 2 via a new self-hosted **SmartScaleConnect**
  instance (`AlexxIT/SmartScaleConnect`), run as a Kubernetes CronJob (twice daily) that
  pulls the latest weighing from the Zepp Life cloud and pushes it to a new Home Assistant
  webhook + automation — the same "HA is the ingestion point" convention used by every
  other integration in this instance
- Add the Amazfit Helio band via the **zepp2hass** HACS integration (already using HACS in
  this instance for `huawei_solar`). This is attempted despite the Helio not appearing in
  zepp2hass's documented supported-device list — see design.md for the verification step
  and fallback if it turns out not to work
- New ingestion bridge: an HA automation forwards new readings to an n8n workflow, which
  calls a new agent-api endpoint that appends them to the Health & Fitness agent's private
  workspace (JSONL history files) — the same per-agent workspace pattern Finance Advisor
  uses for `watchlist.json`, chosen instead of a new database so this stays low-footprint on
  an already resource-constrained single-node cluster
- Register a new **Health & Fitness Advisor** domain agent in agent-api's `agents.yaml`
  (`memory: true`), following the Finance Advisor pattern exactly: reads the workspace
  history, identifies tendencies (weight/body-composition trends, plus steps/sleep/resting
  heart rate/stress if the band path works), and gives recommendations. Reachable via
  Telegram on-demand queries and a scheduled weekly summary (n8n cron, mirroring Finance's
  daily 08:00 CET pattern)
- The agent's LangGraph implementation, its tools, and the new ingestion endpoint are all
  code in the external `agent-api` repo — out of scope for this repo's changes. This
  proposal documents the plan/infra/config side only, the same boundary
  `docs/agent-platform.md` already draws around Finance Advisor's Phase 6

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None.

This is a homelab home-automation and agent-platform change with no documented external
behavior contract tracked as an OpenSpec capability in this repo — consistent with
`migrate-homebridge-to-home-assistant`, `add-tesla-solar-charging`, and
`add-conversational-ai-homepod`, all of which set `skip_specs: true`. The Health & Fitness
agent follows the same precedent already set by Finance Advisor (Phase 6 of
`docs/agent-platform.md`), which was never tracked as a capability spec either. Same here.

## Impact

- **Added**: `my-apps/smartscale-connect/` (new tiny Argo CD-managed app — CronJob,
  namespace, kustomization, ExternalSecret for the Zepp/Xiaomi account credentials via
  Doppler — picked up automatically by the existing git-directory generator in
  `my-apps/myapplications-appset.yaml`); zepp2hass HACS custom_component installed into the
  existing `home-assistant` app (lives in HA's own HACS-managed `custom_components`/
  `.storage` on the PVC, never in git — same convention as every other integration in this
  instance); new HA automation(s) (UI-authored, stored in `automations.yaml` on the PVC,
  not GitOps)
- **Modified**: `agents/platform/agent-api/configmap.yaml` (new `health` entry in
  `agents.yaml`)
- **Modified (external repo, out of scope here)**: `agent-api` — new `health` LangGraph
  graph and tools, a new workspace-ingestion endpoint, Telegram router health-intent
  routing
- **Added**: new n8n workflow(s) for the HA → agent-api ingestion bridge and the scheduled
  weekly summary
- **Physical/manual**: HACS install of `zepp2hass`, Zepp Store mini-app install/config on
  the watch (contingent on the Helio verification step), Zepp/Xiaomi account credential
  provisioning into Doppler
- **Not affected**: HA recorder retention/config for other entities, the existing
  `assistant`/`finance`/`ecommerce` agents, `my-apps/home-assistant`'s existing integrations
