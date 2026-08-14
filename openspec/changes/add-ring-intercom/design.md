## Context

See proposal.md - Why. Home Assistant is already the single smart-home hub in this
instance (`migrate-homebridge-to-home-assistant`, `add-tesla-solar-charging`), with
an existing HomeKit Bridge re-exposing migrated/new devices to Apple Home, and a
convention that every integration's credentials live in HA's own `.storage` on the
PVC, never in git. This change follows both conventions rather than introducing
anything new.

Unlike `huawei_solar`/`xiaomi_home` (HACS) or the Tesla Fleet key-hosting work,
**Ring is a core Home Assistant integration** — no HACS install, no custom
component, no new `my-apps/` manifest. The Intercom is already physically installed
and wired to the existing door control; this change is HA-side software only.

## Goals / Non-Goals

**Goals:**
- Bring the Intercom's door-open action and ring/unlock activity into Home
  Assistant, the same as every other device in this instance
- Re-expose those entities to Apple Home via the existing HomeKit Bridge
- Zero new infrastructure or git-tracked manifests — config lives in `.storage`
  on the PVC like every other integration here

**Non-Goals:**
- Any automation using the Intercom (auto-unlock, ring notifications) —
  deliberately deferred to a later change. This one only brings the device into
  HA, matching `migrate-homebridge-to-home-assistant`'s own non-goal ("getting
  devices into HA, not the automations that will eventually use them")
- Two-way audio/live call from within Home Assistant — not achievable regardless
  of scope: HA's Ring integration documents two-way audio as unsupported; talking
  to a visitor stays in the Ring app either way
- `ring-mqtt` or any other self-hosted bridge (see Decision 1)
- Any physical/installation change to the Intercom or door control wiring —
  already done

## Decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Integration | **Core Home Assistant `ring` integration** (Settings → Devices & Services, built-in). Rejected: `ring-mqtt` (self-hosted Docker bridge) — its own README is explicit that it uses the same undocumented Ring cloud API and does not enable local control, and its main value-add over core (an RTSP gateway for camera live-view) doesn't apply to a camera-less Intercom. It would cost a new container plus a new MQTT broker (neither exists in this cluster today) for no net-new capability here |
| 2 | Entities brought in | **`button`** (open door), **`event`** (ring/unlock activity), **`number`** ×2 (intercom voice volume, intercom mic volume) — the documented Intercom surface. The legacy `binary_sensor` for the same activity is superseded by the `event` entity (HA's own docs flagged this migration as complete by release 2025.4.0, well before this instance's version) — use `event`, not `binary_sensor` |
| 3 | Audio | **Not exposed as a live feature in HA** — HA's Ring integration documents two-way audio as unsupported; the only audio-related entities are the two volume `number`s. Talking to a visitor remains a Ring-app-only capability |
| 4 | Apple Home exposure | **Add to the existing HomeKit Bridge's exposed-entities list** (Settings → Devices & Services → HomeKit Bridge → Configure), per the same convention as every other migrated device. Lives in `.storage`, not git |
| 5 | Credential storage | HA's own **`.storage`** on the PVC, via the integration's config flow (username/password + one-time 2FA code) — identical convention to Tuya, MELCloud, `xiaomi_home`, Tesla Fleet. No Sealed Secret, no git-tracked credential |
| 6 | Automations | **None in this change** — see Non-Goals |

## Risks / Trade-offs

> **Two-way audio is a hard HA limitation, not a config choice.** → Mitigation:
> none needed beyond not promising it — the Ring app remains the only way to
> actually talk to a visitor. A future automation can still react to the
> ring/unlock `event` (e.g., a notification), just without carrying the audio.

> **HomeKit Bridge domain coverage for `button`/`event` entities isn't confirmed.**
> HA's `homekit` component has dedicated accessory handling for locks, switches,
> sensors, and (matching Apple's native HomeKit "Doorbell" service) a `doorbell.py`,
> but no obviously dedicated button-domain file. → Mitigation: verify directly in
> the Home app after adding the entities; if the door-open button doesn't appear
> as a usable accessory, wrap it in a `script`/`scene` helper instead (both are
> well-supported HomeKit-bridge domains) purely for the Apple Home path — the core
> Ring integration and its native HA entities are unaffected either way.

> **Realtime ring/unlock events need outbound TCP 5228** from the Home Assistant
> pod to Ring's event service (per HA's own docs). This node's `ufw` defaults to
> deny **inbound** only (outbound is allowed by default) — a different direction
> from the inbound gap hit during the Homebridge migration (port 8123) — but worth
> confirming empirically given this repo's track record of network assumptions
> not holding on the first try. → Mitigation: after setup, confirm ring/unlock
> events arrive in real time rather than lagging on the ~60s poll; check `ufw
> status`/outbound rules if they don't.

> **Ring's "Authorized Client Devices" growth**: HA versions before 2023.12.0
> registered a new authorized device on every restart, eventually causing event
> instability (per HA's own troubleshooting docs). Current versions shouldn't,
> but if ring/unlock events stop arriving later, check/clean up
> [Ring's Control Center](https://account.ring.com/account/control-center/authorized-devices)
> before assuming something else is broken.

> **The door-open button is callable by anyone with Home Assistant UI or Apple
> Home access** — same trust boundary as the rest of this HA instance (password +
> MFA + `ip_ban_enabled`, per `migrate-homebridge-to-home-assistant` Decision 5);
> no additional confirmation step is added here since no automation is in scope.
> Worth reconsidering if/when an auto-unlock automation is proposed later.

## Migration Plan

1. Add the **Ring** integration (Settings → Devices & Services → Add Integration
   → Ring), sign in with the Ring account, complete the 2FA step.
2. Confirm the Intercom appears with the expected entities (Developer Tools →
   States): one `button`, one `event`, two `number`s. If the Ring account has
   other devices, they'll be added too — out of scope, leave them alone.
3. Test the open-door button once and confirm the physical relay fires; watch
   the `event` entity update in real time (not just every ~60s) to confirm the
   port-5228 realtime path is open.
4. Add the three entities to the existing HomeKit Bridge's exposed-entities list;
   confirm they appear in the Apple Home app.
5. If the button doesn't behave usefully in the Home app, add a small
   `script`/`scene` wrapper and expose that instead (see Risks above).

**Rollback:** nothing destructive. To abort, remove the Ring integration entry
(Settings → Devices & Services → Ring → Delete) and, if added, remove the
entities from the HomeKit Bridge's filter. No manifests or git changes involved.

## Open Questions

1. Will the `button` (open door) and `event` (ring/unlock) entities actually
   surface as usable Home app accessories once added to the HomeKit Bridge
   filter, or does the bridge need a `script`/`scene` wrapper for these domains?
   Doesn't change the chosen approach — only whether the wrapper step (Migration
   Plan step 5) is needed. To be confirmed live during implementation.
2. Is the Intercom mains-powered/wired (no `battery` sensor) or does it report
   one? Affects only which `sensor` entities exist, not the integration approach.
