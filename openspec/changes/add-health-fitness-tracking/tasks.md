## 1. Phase 0 — Verification

- [ ] 1.1 Confirm the Amazfit Helio is paired in the Zepp app; open the Zepp Store on the
      phone and search for "zepp2hass" — confirm whether it shows as installable for this
      device. Record the result (see design.md Open Question 2).
- [ ] 1.2 If not installable: stop band-related work here — skip Phase 2 entirely and note
      that this change ships scale-only (per design.md's fallback).
- [ ] 1.3 Confirm the exact Xiaomi scale model in the Zepp Life app (Device → About device)
      matches Mi Body Composition Scale 2 (XMTZC05HM) as expected.

## 2. Phase 1 — Scale ingestion (SmartScaleConnect → Home Assistant)

- [ ] 2.1 Provision the Zepp/Xiaomi account credentials in Doppler (new secret), following
      the same convention as every other secret added since Sealed Secrets was retired.
- [ ] 2.2 Create `my-apps/smartscale-connect/`: `namespace.yaml`, `externalsecret.yaml`
      (sourcing the Doppler secret), `cronjob.yaml` (SmartScaleConnect image pinned to a
      specific released version tag — not `latest`, schedule twice daily, config
      `from: zepp/xiaomi {username} {password}` → `to: json <HA webhook URL>`),
      `kustomization.yaml`.
- [ ] 2.3 Push and let Argo CD sync; confirm the CronJob's first run completes successfully
      and the pod logs show a weighing was found and sent.
- [ ] 2.4 In Home Assistant, add a webhook trigger + automation to receive the pushed
      reading (native entities — e.g. `input_number`/`input_text` helpers set from the
      webhook payload, same spirit as SmartScaleConnect's own "To: Home Assistant" example).
- [ ] 2.5 Verify a real weighing shows up in HA's own entity history within one CronJob
      cycle.

## 3. Phase 2 — Band ingestion (zepp2hass → Home Assistant) — only if Phase 0 confirmed feasibility

- [ ] 3.1 Install `zepp2hass` via HACS (Settings → HACS → search "Zepp2Hass" → Download);
      restart Home Assistant.
- [ ] 3.2 Add the Zepp2Hass integration in HA (Settings → Devices & Services), name the
      device, retrieve its webhook URL.
- [ ] 3.3 Install the `zepp2hass` mini-app on the watch via the Zepp Store (phone app);
      configure it with the webhook URL and an update interval (2-5 min, per the
      integration's own battery-life guidance).
- [ ] 3.4 Apply settings on the watch itself; confirm sensors (heart rate, steps, sleep,
      stress, SpO2, battery, etc.) appear in HA within a few minutes.
- [ ] 3.5 If sensors don't appear or the mini-app isn't usable on this device: fall back to
      scale-only scope (per design.md Risk #1) and skip the rest of this phase.

## 4. Phase 3 — Local persistence bridge (HA → n8n → agent-api workspace)

- [ ] 4.1 Add a new agent-api HTTP endpoint (external `agent-api` repo) that accepts a
      health reading payload and appends it to the Health & Fitness agent's workspace as
      JSONL (one file per source, e.g. `scale_readings.jsonl` / `band_metrics.jsonl`).
- [ ] 4.2 Add a new n8n workflow: webhook trigger → calls the new agent-api endpoint with
      the incoming payload.
- [ ] 4.3 Wire the HA automations from Phase 1 (and Phase 2, if applicable) to call this
      n8n webhook whenever a new reading arrives.
- [ ] 4.4 Verify end-to-end: trigger a reading (or wait for the next CronJob run) and
      confirm a new line appears in the workspace JSONL file.

## 5. Phase 4 — Health & Fitness agent

- [ ] 5.1 Register the `health` agent in `agents/platform/agent-api/configmap.yaml`
      (`agents.yaml`): name, description, `graph: health`, `default_tier: fast`,
      `memory: true`.
- [ ] 5.2 (external `agent-api` repo) Implement the `health` LangGraph graph and its tools
      (read workspace history, summarize trends), following the Finance Advisor pattern.
- [ ] 5.3 Add health-intent detection to the existing Telegram router, routing to
      `/agents/health/invoke` (same pattern as Finance).
- [ ] 5.4 Add an n8n cron workflow for a weekly scheduled summary →
      `POST /agents/health/invoke` → Telegram (mirrors Finance's daily 08:00 CET workflow,
      but weekly).
- [ ] 5.5 Verify: an on-demand Telegram query returns a sensible trend/recommendation
      response, and the scheduled summary fires and delivers on schedule.

## 6. Phase 5 — Wrap-up

- [ ] 6.1 Add `smartscale-connect` to the `my-apps/` tree listing in `docs/architecture.md`.
- [ ] 6.2 Add the `health` agent to the agent inventory in `docs/agent-platform.md`
      (mirroring the Finance Advisor Phase 6 entry).
- [ ] 6.3 After a few days of twice-daily syncs, confirm the Zepp/Xiaomi account shows no
      2FA/lockout prompts and the CronJob needs no further maintenance.
