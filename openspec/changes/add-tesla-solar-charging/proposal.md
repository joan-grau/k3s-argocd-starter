## Why

The Tesla is charged through a Mobile Connector, which has no network connectivity or
monitoring of its own. Home Assistant currently has no visibility into when the car is
plugged in or charging, and nothing coordinates its load with the existing Huawei solar
+ battery system (`huawei_solar`, already integrated in
`migrate-homebridge-to-home-assistant`). Without coordination, EV charging silently
draws down the home battery instead of preferring solar surplus or, failing that, the
grid.

## What Changes

- Add the core Home Assistant **Tesla Fleet** integration to monitor the vehicle
  (plugged-in state, charging state, charger power/current/voltage) and control it
  (start/stop charging, adjust charge current)
- One-time Tesla Developer Application registration, plus a small self-hosted
  static-file service and a new `cloudflared` ingress rule to host the Fleet API's
  required public key at
  `https://homeassistant.pascualgrau.com/.well-known/appspecific/com.tesla.3p.public-key.pem`
- Add a solar-aware charging automation (built in the HA UI, same as every other
  automation in this instance) with two layers:
  - Continuously match the Tesla's charge current to live solar surplus, using the
    existing `huawei_solar` sensors (efficiency — minimizes grid draw too)
  - While the car is plugged in/charging, use `huawei_solar`'s Capacity Control
    feature to reserve the battery at its current state of charge, so any shortfall
    is drawn from the grid instead of the battery (the actual guarantee — the
    surplus-matching layer alone can't be, due to polling latency on both sides)
  - Pause charging entirely when solar surplus falls below the Mobile Connector's
    minimum sustainable charge rate, rather than exceeding it
- Verify (and if needed, enable) prerequisites on the existing `huawei_solar`
  integration: Elevate permissions, and the "Charge from Grid" toggle required by
  Capacity Control

## Capabilities

### New Capabilities

None.

### Modified Capabilities

None.

This is a homelab home-automation change with no documented external behavior
contract tracked as an OpenSpec capability in this repo — consistent with
`migrate-homebridge-to-home-assistant` and `migrate-sealed-secrets-to-doppler`, both
of which also set `skip_specs: true`. Same here.

## Impact

- **Added**: `my-apps/tesla-fleet-key/` (new tiny Argo CD-managed app, picked up
  automatically by the existing git directory generator in
  `my-apps/myapplications-appset.yaml`); Tesla Fleet integration config (OAuth
  credentials and the generated signing key live in Home Assistant's own
  `config`/`.storage` on the PVC, never in git); new HA automations (UI-managed,
  stored in `automations.yaml` on the PVC — same convention as the rest of this HA
  instance, not GitOps)
- **Modified**: `infrastructure/networking/cloudflared/config.yaml` (one new
  path-scoped ingress rule, ordered before the existing `homeassistant.pascualgrau.com`
  rule); possibly the existing `huawei_solar` integration's configuration (Elevate
  permissions / Charge from Grid, if not already enabled)
- **Physical/manual**: Tesla Developer Application registration (developer.tesla.com),
  virtual key pairing via the Tesla phone app, one-time `huawei_solar` reconfiguration
  if its prerequisites aren't already on
- **Not affected**: `agents/platform`, the rest of `my-apps/`, the
  `migrate-homebridge-to-home-assistant` change itself
