## Context

See proposal.md - Why. Two systems already exist and this change wires them together:

- **`huawei_solar`** (HACS, Modbus) is already integrated per `migrate-homebridge-to-home-assistant`,
  exposing production/consumption/battery sensors (e.g. `sensor.power_meter_active_power`,
  `sensor.battery_charge_discharge_power`, `sensor.battery_state_of_capacity` — the
  parent change's own design.md flags these as best-guess defaults, not read from the
  live instance; this change must confirm the real entity IDs via Developer Tools →
  States before wiring any automation to them).
- **Home Assistant itself** runs as a plain container Deployment in k3s (`my-apps/home-assistant/`),
  not Home Assistant OS/Supervised. This rules out the Home Assistant docs' recommended
  "NGINX Home Assistant SSL proxy" *Supervisor add-on* for hosting the Tesla Fleet public
  key — that add-on ecosystem doesn't exist here.
- Public access to `homeassistant.pascualgrau.com` is via Cloudflare Tunnel
  (`infrastructure/networking/cloudflared/config.yaml`), which maps each public
  hostname straight to a Kubernetes Service — separate from, and in addition to, the
  internal Gateway API / HTTPRoute setup used for `homeassistant.lan`. All existing
  cloudflared ingress rules are hostname-only today; this change introduces the
  repo's first path-scoped rule.
- Every other integration's credentials in this HA instance (Xiaomi, Tuya, MELCloud)
  live in `.storage` on the PVC, never in git; every automation is built in the HA UI
  and lives in `automations.yaml` on the PVC, never in git. This change follows both
  conventions rather than introducing GitOps-managed automations.

## Goals / Non-Goals

**Goals:**
- Monitor the Tesla's plugged-in and charging state in Home Assistant
- Prefer solar surplus for charging; when surplus is insufficient, draw the shortfall
  from the grid — never from the home battery
- Reuse existing infrastructure (Cloudflare Tunnel, `huawei_solar`) with the smallest
  possible new footprint

**Non-Goals:**
- A general price-based smart-charging system (e.g. charge at the cheapest grid
  hours) — out of scope. The HACS **EV Smart Charging** integration has native Tesla
  Fleet support and could cover this later as its own change; it doesn't address the
  solar/battery goal here on its own
- Any change to the Mobile Connector hardware, or a future Wall Connector — this
  design assumes a fixed ~10A single-phase (~2.3kW) circuit
- Multi-vehicle support
- Rebuilding `huawei_solar`'s own dashboards/sensors — only its battery control
  surface is new ground here

## Decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Vehicle integration | **Tesla Fleet** (core HA, since 2024.8, Cloud Polling) — the only actively-maintained path today. Rejected: `tesla_custom` / TeslaMate command APIs, both built on owner-api tokens Tesla has been locking down since 2023 |
| 2 | Public key hosting | **Self-hosted**: a tiny static-file pod (`my-apps/tesla-fleet-key/`) plus a new path-scoped `cloudflared` ingress rule. Rejected: FleetKey.net / MyTeslamate.com — free third-party services, but they'd hold the public key used to authorize signed vehicle commands; self-hosting costs one small pod and stays consistent with this repo's fully self-hosted posture (own tunnel, own cert-manager, own gateway) |
| 3 | Static file server image | **busybox httpd**, not nginx — nginx's common default `location ~ /\.` deny-all rule is a known gotcha for dot-prefixed paths like `/.well-known/...` (the same class of issue that trips up ACME HTTP-01 challenges). busybox httpd serves whatever's on disk with no config file and no such rule |
| 4 | Battery guarantee mechanism | `huawei_solar`'s **Capacity Control** feature (`select` Capacity control mode, "Peak shaving SOC", `huawei_solar.set_capacity_control_periods`), toggled by automation when the car plugs in/unplugs. Rejected: `huawei_solar.forcible_charge` / `forcible_discharge` services — these force *more* charging or discharging to a target SOC, the opposite of "leave the battery alone" |
| 5 | Charge-rate control | Proportional: continuously match `number.<car>_charge_current` to live solar surplus. The floor is read from that entity's own `min` attribute at runtime (typically ~5A for Tesla vehicles), never hardcoded — below it, pause via `switch.<car>_charge` rather than under-shooting the minimum |
| 6 | Automation ownership | Home Assistant UI, stored in `automations.yaml` on the PVC — consistent with every other automation in this instance. Not GitOps-managed |
| 7 | Circuit rating | ~10A single-phase (confirmed by user), ~2.3kW max — sets the practical ceiling for charge-current matching |

## Risks / Trade-offs

> **Capacity Control keeps the inverter/battery out of standby the entire time it's
> active**, drawing a constant ~75–125W even when idling, per the `huawei_solar`
> wiki. → Mitigation: the automation must disable Capacity Control again as soon as
> the car stops charging/unplugs, not leave it on permanently.

> **"Charge from Grid" is a prerequisite toggle for Capacity Control** and may not
> already be enabled on the existing `huawei_solar` setup. → Mitigation: verify
> today's Working Mode / TOU settings first, so enabling it doesn't silently change
> normal (non-EV-charging) battery behavior. Treated as a Phase 0 check, not assumed.

> **Reconfiguring `huawei_solar`** (if Elevate permissions turns out not to be
> enabled) briefly interrupts the single Modbus connection Huawei allows to the
> inverter. → Mitigation: do this as a deliberate, isolated step, not mid-automation.

> **Control loop latency**: `huawei_solar` polls every 30s by default; Tesla Fleet
> refreshes vehicle *state* roughly every 10 minutes while awake (commands are sent
> immediately, but confirmation lags). → Mitigation: this is exactly why Decision 4
> exists — the surplus-matching layer (Decision 5) is best-effort/efficiency-only, the
> Capacity Control layer is the actual hard guarantee against battery discharge,
> independent of automation timing.

> **Capacity Control Periods must cover the entire week** (up to 14 periods, format
> `<start>-<end>/<days>/<peak power>W`). → Mitigation: use a single all-week/all-day
> period with a very high peak-power value (e.g. `00:00-23:59/1234567/20000W`) as the
> "car is charging" state, rather than trying to patch a partial-week schedule — keeps
> the config simple and avoids gaps.

> **`cloudflared`'s ConfigMap is subPath-mounted and does not hot-reload** — hit
> already during the parent change's Phase 5 (the pod kept serving stale ingress
> rules until a manual restart). → Mitigation: the new ingress rule needs
> `kubectl rollout restart daemonset/cloudflared -n cloudflared` after Argo CD syncs
> it, same as last time.

> **Tesla's $10/month Fleet API credit** should cover default polling for one
> vehicle, but is worth checking in the Tesla Developer Dashboard after the first
> few days.

## Migration Plan

1. Deploy `my-apps/tesla-fleet-key/` with a placeholder key file — Argo CD picks it
   up automatically, no ApplicationSet change needed (same pattern as every other
   `my-apps/` addition).
2. Complete the Tesla Developer Application and the Tesla Fleet integration's config
   flow in HA up to "Register public key"; copy the real key into the ConfigMap
   (hash-suffixed generator, same as `home-assistant-configuration`, so updating it
   rolls the pod automatically).
3. Add the path-scoped rule to `infrastructure/networking/cloudflared/config.yaml`,
   ordered before the existing `homeassistant.pascualgrau.com` rule; manually restart
   the `cloudflared` DaemonSet once, as noted above.
4. Finish pairing the virtual key per vehicle via the Tesla app.
5. Build and verify the two automations in the HA UI.

**Rollback:** nothing here is destructive to existing systems. To abort: remove the
Tesla Fleet integration from Settings → Devices & Services, delete the automations,
revert the `cloudflared` ingress rule (with another manual DaemonSet restart), and
`rm -rf my-apps/tesla-fleet-key`. The Tesla Developer Application can be deleted from
the Tesla Developer Dashboard independently. None of this touches `huawei_solar`'s
existing sensors/dashboards or any other app.

## Open Questions

1. Is "Elevate permissions" actually enabled on the existing `huawei_solar` config?
   The user wasn't certain ("I can change the config... so I guess I do") — being
   able to reconfigure the integration's connection settings is not the same as
   having checked that box. Must be confirmed directly (Developer Tools → Services,
   check whether `huawei_solar.forcible_charge`/`set_capacity_control_periods` are
   listed) before relying on Decision 4. Doesn't change the approach — only whether a
   one-time reconfiguration step is needed first.
2. Exact live entity IDs for the car (depends on its name in the Tesla app) and for
   `huawei_solar`'s Capacity Control entities — to be read from the running instance
   during implementation, not assumed from documentation examples.
