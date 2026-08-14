## Why

There's a Ring Intercom already installed, wired into the existing building door
control (buzzer/release) — no camera, just an intercom speaker/mic and a relay to
open the door. It's currently only usable through the Ring app. Home Assistant is
already this home's single smart-home hub (`migrate-homebridge-to-home-assistant`,
`add-tesla-solar-charging`); the Intercom should be there too, so opening the door
and seeing "someone's at the door" activity is available alongside every other
device, and reachable from Apple Home like the rest.

## What Changes

- Add the core Home Assistant **Ring** integration (Settings → Devices & Services),
  scoped to the Intercom device only
- Bring in the entities it exposes for an Intercom: a **button** to open the door,
  an **event** entity for ring/unlock activity, and **number** entities for
  intercom voice/mic volume
- Re-expose those entities to Apple Home via HA's existing **HomeKit Bridge**, same
  convention as every other migrated device
- No automations yet — this change only brings the device into HA (see
  design.md Non-Goals)

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None.

This is a homelab home-automation device integration with no documented external
behavior contract tracked as an OpenSpec capability in this repo — consistent with
`migrate-homebridge-to-home-assistant` and `add-tesla-solar-charging`, both of
which also set `skip_specs: true`. Same here.

## Impact

- **Added**: Ring core integration config (OAuth/session token lives in Home
  Assistant's own `.storage` on the PVC, never in git — same convention as every
  other integration in this instance); the Intercom's entities added to the
  existing HomeKit Bridge's exposed-entities list (also `.storage`, not git)
- **Modified**: None in this repo — no manifests change. The only git-tracked
  file this could touch is `docs/architecture.md` if the device inventory is
  worth recording there
- **Physical/manual**: Ring account login (username/password + 2FA code) during
  the integration's config flow in the HA UI; confirming the HomeKit Bridge's
  entity filter picks up the new entities
- **Not affected**: `agents/platform`, the rest of `my-apps/`, every other
  existing integration (`huawei_solar`, MELCloud, `xiaomi_home`, Tuya, Tesla
  Fleet)
