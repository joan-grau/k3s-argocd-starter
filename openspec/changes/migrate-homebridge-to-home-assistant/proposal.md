## Why

Homebridge was only ever a shim to expose non-HomeKit devices (Xiaomi, Tuya) to the
Apple Home app / HomePod. Home Assistant replaces it with first-class integrations,
a real automation engine, and its own HomeKit Bridge for the Apple side.

Scope expanded 2026-08-01: this is no longer just a Homebridge replacement. HA
becomes the single smart-home automation hub — the Aqara Hub M2 (currently paired
directly to Apple Home), a Huawei/FusionSolar inverter, and a Mitsubishi ducted AC
unit are all being brought into HA so everything can be automated in one place.
Apple Home becomes a HomeKit *display* layer via HA's HomeKit Bridge, not the
source of truth. Also added the same day: a Xiaomi Robot Vacuum S20 and a Mi 360
security camera.

## What Changes

- Migrate all Homebridge-bridged devices (2× Xiaomi smart plugs, Xiaomi heater,
  2× Tuya Smart Life switches) to native Home Assistant integrations
- Bring the Aqara Hub M2 (5 sensors/buttons) into HA via HomeKit Controller,
  alongside its existing direct pairing to Apple Home
- Add net-new integrations for devices that never went through Homebridge:
  Huawei/FusionSolar inverter (`huawei_solar`), Mitsubishi ducted AC (MELCloud),
  Xiaomi Robot Vacuum S20, and a Mi 360 security camera
- Re-expose every migrated device to Apple Home via HA's own HomeKit Bridge,
  reusing the exact old accessory names so existing Siri phrases keep working
- Publish HA externally via Cloudflare Tunnel, behind a Cloudflare Access policy
  (not raw — see design.md Decision #5)
- Decommission Homebridge once cutover is verified, keeping a Longhorn snapshot
  and this change as the historical record
- Cut over as a parallel run: Home Assistant is deployed and verified alongside
  the still-running Homebridge (host ports don't collide) before anything old is
  removed

n8n (`agents/platform/n8n`) is scoped to the agent platform only and is not part
of this migration — HA's own automation engine is the sole automation layer for
smart-home devices.

## Capabilities

### New Capabilities

None. This is a homelab infrastructure/home-automation migration — it changes
which system manages physical devices, not a documented external behavior
contract tracked as an OpenSpec capability in this repo. `skip_specs: true` is
set in `.openspec.yaml`.

### Modified Capabilities

None.

## Impact

- **Added**: `my-apps/home-assistant/` (new Argo CD-managed application; picked
  up automatically by the existing git-directory generator in
  `my-apps/myapplications-appset.yaml`, no ApplicationSet change needed)
- **Removed (Phase 4)**: `my-apps/homebridge/`, and the
  `homebridge.pascualgrau.com` entry in
  `infrastructure/networking/cloudflared/config.yaml`
- **Updated**: `docs/architecture.md` — drop Homebridge from the `my-apps/` tree
  listing, add Home Assistant
- **Physical/manual**: Apple Home app re-pairing (rooms, scenes, automations
  have no export and must be rebuilt), Tuya/Smart Life account password
  rotation, Mi 360 firmware modification (device-level, outside Kubernetes/
  GitOps entirely)
- **Not affected**: `agents/platform/n8n` and the wider agent platform
