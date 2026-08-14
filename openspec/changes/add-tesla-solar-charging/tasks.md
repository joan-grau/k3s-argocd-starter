## 1. Phase 0 — Prep / verification

- [ ] 1.1 Confirm whether "Elevate permissions" is actually enabled on the existing
      `huawei_solar` integration (Developer Tools → Services → check whether
      `huawei_solar.forcible_charge` / `huawei_solar.set_capacity_control_periods`
      are listed). See design.md Open Question 1.
- [ ] 1.2 If not enabled: reconfigure the `huawei_solar` integration (dropdown menu
      → Reconfigure), check "Elevate permissions", enter the installer account
      credentials (default `00000a` or `0000000a` unless already changed).
- [ ] 1.3 Review the inverter's current Working Mode / TOU settings before touching
      anything, so enabling the "Charge from Grid" toggle's effect on today's normal
      behavior is understood, not assumed.
- [ ] 1.4 Enable "Charge from Grid" if not already on (prerequisite for Capacity
      Control).
- [ ] 1.5 Confirm the real `huawei_solar` entity IDs against the live instance
      (Developer Tools → States) — production, consumption, battery SOC, Capacity
      control mode, Peak shaving SOC. Don't assume the parent change's best-guess
      names are correct.
- [ ] 1.6 Register a Tesla Developer Application at
      [developer.tesla.com/request](https://developer.tesla.com/request) — OAuth
      Grant Type "Authorization Code and Machine-to-Machine", scopes: Vehicle
      Information, Vehicle Location, Vehicle Commands. Note the Client ID/Secret.

## 2. Phase 1 — Public key hosting

- [ ] 2.1 Create `my-apps/tesla-fleet-key/`: `namespace.yaml`, `deployment.yaml`
      (busybox httpd serving a ConfigMap-mounted file — avoids nginx's default
      dotfile-deny rule tripping up the `.well-known` path), `service.yaml`,
      `kustomization.yaml` with a `configMapGenerator` (hash suffix, same pattern as
      `home-assistant-configuration`) sourcing a placeholder
      `com.tesla.3p.public-key.pem`.
- [ ] 2.2 Push and let Argo CD sync; confirm the pod is running and serves the
      placeholder file internally (`kubectl -n tesla-fleet-key port-forward` + curl,
      or similar).
- [ ] 2.3 Add a path-scoped rule to
      `infrastructure/networking/cloudflared/config.yaml` for
      `homeassistant.pascualgrau.com` + path
      `/.well-known/appspecific/com.tesla.3p.public-key.pem`, pointing at the new
      service — **ordered before** the existing (path-less) `homeassistant.pascualgrau.com`
      rule, since cloudflared matches top-to-bottom.
- [ ] 2.4 Manually restart the `cloudflared` DaemonSet once this syncs
      (`kubectl rollout restart daemonset/cloudflared -n cloudflared`) — its
      ConfigMap is subPath-mounted and won't hot-reload, same issue hit in the
      parent change's Phase 5.
- [ ] 2.5 Verify the placeholder key is reachable at
      `https://homeassistant.pascualgrau.com/.well-known/appspecific/com.tesla.3p.public-key.pem`
      from the public internet, and that every other path on that hostname still
      reaches Home Assistant unaffected.

## 3. Phase 2 — Tesla Fleet integration setup

- [ ] 3.1 Add the **Tesla Fleet** integration in HA (Settings → Devices & services →
      Add integration), enter the Client ID/Secret from 1.6.
- [ ] 3.2 Complete the OAuth login, select all requested scopes, confirm "Link
      account to Home Assistant".
- [ ] 3.3 Enter `homeassistant.pascualgrau.com` as the domain when prompted.
- [ ] 3.4 Copy the public key HA shows you into the real
      `com.tesla.3p.public-key.pem` file backing the `tesla-fleet-key`
      `configMapGenerator`; push and confirm Argo CD rolls the pod (new hash
      suffix).
- [ ] 3.5 Re-verify the **real** key (not the placeholder) is now served at the
      public well-known URL.
- [ ] 3.6 Finish "Install Virtual Key" — scan the QR code (or visit
      `https://tesla.com/_ak/homeassistant.pascualgrau.com`) in the Tesla phone app
      for the vehicle.
- [ ] 3.7 Confirm the vehicle appears in HA with live entities (Developer Tools →
      States) — note the actual entity IDs (`binary_sensor.<car>_charge_cable`,
      `sensor.<car>_charging`, `number.<car>_charge_current`,
      `switch.<car>_charge`, etc.) instead of assuming a name.

## 4. Phase 3 — Capacity Control dry run (manual, before automating)

- [ ] 4.1 Manually call `huawei_solar.set_capacity_control_periods` with a single
      all-week period at a high peak power, e.g. `00:00-23:59/1234567/20000W`.
- [ ] 4.2 Manually set "Peak shaving SOC" to the battery's current SOC reading, then
      switch "Capacity control mode" to Active.
- [ ] 4.3 Confirm via the battery SOC/charge-discharge-power sensors that the
      battery holds and does not discharge under a normal house load.
- [ ] 4.4 Revert (Capacity control mode → off/previous) and confirm normal
      self-consumption behavior resumes.
- [ ] 4.5 Note the ~75–125W idle draw increase observed while Capacity Control is
      active, to confirm it's acceptable given it will only run during charging
      sessions.

## 5. Phase 4 — Automations (built in the HA UI, stored in `automations.yaml` on the PVC — not GitOps, same convention as every other automation in this instance)

- [ ] 5.1 "EV connected" helper automation: track
      `binary_sensor.<car>_charge_cable` so the other automations read a stable
      state.
- [ ] 5.2 Solar-surplus matching automation: on solar/consumption sensor updates,
      while the cable is connected, set `number.<car>_charge_current` toward
      (solar production − house load), reading the entity's own `min` attribute as
      the floor rather than hardcoding one; below that floor, turn
      `switch.<car>_charge` off instead of under-shooting it.
- [ ] 5.3 Capacity Control guard automation: when charging starts (cable connects /
      `switch.<car>_charge` turns on), apply the Phase 3 steps (4.1–4.2)
      automatically; when charging stops or the cable disconnects, revert (4.4)
      automatically.
- [ ] 5.4 Add hysteresis/smoothing to 5.2 (e.g. only adjust amps if the change is
      above a minimum step, and no more often than every N minutes) to avoid
      rapid contactor cycling on the vehicle side.
- [ ] 5.5 Test end-to-end across scenarios: full sun, a cloud passing mid-charge,
      and evening/no-sun — confirm the battery SOC never drops during any of them
      and the car still charges (from grid) when solar alone is insufficient.
- [ ] 5.6 Test unplug and charge-complete scenarios revert Capacity Control
      correctly (mode off, no lingering idle-draw penalty).

## 6. Phase 5 — Wrap-up

- [ ] 6.1 Add `tesla-fleet-key` to the `my-apps/` tree listing in
      `docs/architecture.md`.
- [ ] 6.2 Check Tesla Developer Dashboard usage after a few days of normal charging
      to confirm it stays within the $10/month free credit.
