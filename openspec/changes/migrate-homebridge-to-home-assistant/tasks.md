## 1. Phase 0 — Prep (do before pushing)

- [x] 1.1 Rotate the Tuya / Smart Life account password and the Tuya IoT API
      secret. They were exposed in plaintext while planning this migration.
- [ ] 1.2 Longhorn snapshot of the `homebridge-config` volume.
- [ ] 1.3 Copy the Homebridge `config.json` off the volume to a safe location
      outside the repo.
- [x] 1.4 Screenshot every room, scene and automation in the Apple Home app —
      re-pairing loses all of it and there is no export.
- [x] 1.5 Huawei dongle Modbus TCP already enabled.
- [x] 1.6 Note the dongle's LAN IP for Phase 2. Progress: dongle LAN IP
      identified (`192.168.0.134`).
- [x] 1.7 Confirm the existing MELCloud app login still works — used directly
      in HA's MELCloud integration, never stored in this repo.
- [x] 1.8 Extract the Xiaomi Robot Vacuum S20's local IP + miIO token (Xiaomi
      Cloud Tokens Extractor). Progress: local IP identified (`192.168.0.23`);
      token extracted and kept outside this repo.
- [ ] 1.9 Identify the Mi 360 camera's exact hardware/firmware revision and
      confirm a matching RTSP hack guide exists before attempting it.

## 2. Phase 1 — Deploy

- [x] 2.1 Push the branch and let Argo CD sync.
- [x] 2.2 `kubectl get app home-assistant -n argocd -w`
- [x] 2.3 `kubectl -n home-assistant get pod -w` — first boot takes 1–3 minutes.
- [x] 2.4 Confirm `homeassistant.lan` resolves to `192.168.0.35` (the `*.lan`
      AdGuard rewrite should already cover it).
- [x] 2.5 Open `https://homeassistant.lan`, complete onboarding, create the
      owner account.
- [x] 2.6 Enable MFA immediately.

## 3. Phase 2 — Integrations

Add via *Settings → Devices & Services → Add Integration*. Credentials land in
`/config/.storage` on the PVC and never touch git.

- [x] 3.1 Add the HACS integration itself first (GitHub device-code login) —
      the files are already on the PVC via the `install-hacs` init container,
      this step only registers the config entry.
- [x] 3.2 HACS `xiaomi_home` — plug @ `192.168.0.30`
- [x] 3.3 HACS `xiaomi_home` — plug @ `192.168.0.31`
- [x] 3.4 HACS `xiaomi_home` — heater `zhimi.heater.mc2a` @ `192.168.0.50` —
      model accepted, working.
- [x] 3.5 Tuya — 2 Smart Life switches via the app user-code / QR flow
- [ ] 3.6 Aqara Hub M2 — HomeKit only supports one paired controller at a
      time. Note the HomeKit pairing code first (sticker on hub/box, or the
      Aqara Home app's hub settings), then remove/unpair the M2 from the Apple
      Home app (unpair only, not a factory reset). Add HA's "HomeKit Device"
      integration and enter the code. Verify all 5 sensors/buttons show up as
      entities. See design.md Decision #7.
- [x] 3.7 Huawei Solar — add `huawei_solar`, point it at the dongle's LAN IP
      (Modbus TCP, default port 6607).
- [x] 3.8 Mitsubishi AC — add MELCloud, sign in with the existing account.
- [x] 3.9 Vacuum S20 — HACS `xiaomi_home` (same Mi account integration as
      plugs/heater) — working.
- [ ] 3.10 Verify every entity actually toggles from the HA UI **before**
      touching HomeKit.

## 4. Phase 2b — Mi 360 camera (isolated, higher risk)

Done independently of the rest of Phase 2 — the camera has no dependency on,
and nothing else depends on, this step.

- [ ] 4.1 Back up / note the stock firmware version and Mi Home pairing state
      before hacking, in case of rollback.
- [ ] 4.2 Apply the community RTSP-enable hack matching the camera's exact
      hardware/firmware revision.
- [ ] 4.3 Confirm the RTSP stream plays externally (VLC/ffprobe) before
      touching HA.
- [ ] 4.4 Add it to HA as Generic Camera (RTSP).
- [ ] 4.5 Rollback: if the hack fails or bricks the camera, restore stock
      firmware / factory reset and re-pair to Mi Home — drop it from this
      migration, nothing else in the plan depends on it.

## 5. Phase 2c — Solar visualization (Power Flow Card Plus)

Cosmetic only, no dependency on Phase 3 or anything after it. Requires the
`huawei_solar` entities from Phase 2 to already be live.

- [x] 5.1 HACS → Frontend → search Power Flow Card Plus → download.
- [x] 5.2 Confirm HACS auto-registered the Lovelace resource (Settings →
      Dashboards → Resources — enable Advanced Mode on your profile if the tab
      is hidden).
- [x] 5.3 Look up the real entity IDs (Developer Tools → States, filter
      `huawei`) — the ones below are the integration's own documented
      defaults, not read from the live instance, and may differ (multi-device
      / custom-named setups get suffixed IDs).
- [x] 5.4 Add a card to a dashboard view with the starting config below, then
      correct entity IDs and flow direction as needed.
- [x] 5.5 Verify grid/battery arrows point the right way; add
      `invert_state: true` on whichever entity is backwards.

  ```yaml
  type: custom:power-flow-card-plus
  entities:
    grid:
      entity: sensor.power_meter_active_power
      display_state: one_way
      color_circle: true
    solar:
      entity: sensor.inverter_active_power
    battery:
      entity: sensor.battery_charge_discharge_power
      state_of_charge: sensor.battery_state_of_capacity
      display_state: one_way
      color_circle: true
  kilo_threshold: 1000
  ```

  Entity IDs above are best-guess defaults, taken from the `huawei_solar`
  integration's own README examples — not read from your live instance.
  Verify and correct them before relying on the card.

## 6. Phase 3 — HomeKit Bridge

- [ ] 6.1 Enable the HomeKit Bridge integration with an explicit entity
      include-filter (do not bridge everything HA auto-creates).
- [ ] 6.2 Include the Aqara M2's 5 entities in this filter — unpairing it from
      Apple Home in Phase 2 means this bridge is the only way Siri/Apple Home
      see them again, same treatment as Xiaomi/Tuya.
- [ ] 6.3 Pair the new bridge in the Apple Home app.
- [ ] 6.4 Rebuild rooms, scenes and automations. Reuse the exact old accessory
      names so existing Siri phrases keep working.
- [ ] 6.5 Test from the HomePod specifically, not just the phone.

## 7. Phase 4 — Decommission Homebridge

- [ ] 7.1 Remove the Homebridge bridge from the Apple Home app.
- [ ] 7.2 Confirm the Longhorn snapshot from Phase 0 exists — deleting the
      Argo CD app prunes the PVC.
- [ ] 7.3 Delete `my-apps/homebridge/`.
- [ ] 7.4 Remove the `homebridge.pascualgrau.com` entry from
      `infrastructure/networking/cloudflared/config.yaml`.
- [ ] 7.5 Update `docs/architecture.md`: drop Homebridge from the `my-apps/`
      tree listing, add Home Assistant.

## 8. Phase 5 — Public access + hardening

- [x] 8.1 ~~Create the Cloudflare Access policy for
      `homeassistant.pascualgrau.com` first.~~ **Decision 2026-08-11**:
      skipped — Access breaks the HA Companion App (browser-login redirect it
      can't complete). See design.md Decision #5 and Risks / Trade-offs.
- [x] 8.2 Add the tunnel ingress entry:
      `http://home-assistant.home-assistant.svc.cluster.local:80`.
- [x] 8.3 Confirm `trusted_proxies` covers the cloudflared pod IPs — already
      did, `10.42.0.0/16` (k3s pod CIDR) is in configuration.yaml.
- [x] 8.4 Re-check MFA and `ip_ban_enabled` — both already on.

  Exposed with password + MFA only, no Cloudflare Access — see the 8.1
  decision note above.

- [x] 8.5 Verified `https://homeassistant.pascualgrau.com` end-to-end from the
      public internet. Two pre-existing infra gaps surfaced and were fixed
      along the way (not Home Assistant config issues) — see design.md
      "Implementation notes (Phase 5)": cloudflared's `subPath`-mounted
      ConfigMap needed a manual pod restart to pick up the new ingress rule,
      and the node's `ufw` firewall had no allow rule for port 8123.
