# Homebridge → Home Assistant Migration

> **Status**: Phase 1 manifests written, **not yet pushed / not yet deployed**.
> Started 2026-08-01.

## Why

Homebridge was only ever a shim to expose non-HomeKit devices (Xiaomi, Tuya) to the
Apple Home app / HomePod. Home Assistant replaces it with first-class integrations,
a real automation engine, and its own HomeKit Bridge for the Apple side.

**Scope expanded 2026-08-01**: this is no longer just a Homebridge replacement. HA
becomes the single smart-home automation hub — the Aqara Hub M2 (currently paired
directly to Apple Home), a Huawei/FusionSolar inverter, and a Mitsubishi ducted AC
unit are all being brought into HA so everything can be automated in one place.
Apple Home becomes a HomeKit *display* layer via HA's HomeKit Bridge, not the source
of truth.

---

## Decisions taken

| # | Decision | Choice |
|---|----------|--------|
| 1 | Pod networking | `hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet` — required for HomeKit Bridge mDNS advertisement and Xiaomi/Tuya LAN discovery |
| 2 | `configuration.yaml` ownership | GitOps — ConfigMap mounted read-only via `subPath`, generated with a hash suffix so edits roll the pod |
| 3 | Recorder database | SQLite on the PVC. **Do not** reuse the `agents/platform` PostgreSQL |
| 4 | HACS / custom components | Deferred — only if the Xiaomi heater turns out to be unsupported by the core integration |
| 5 | Public access | Cloudflare Tunnel **behind a Cloudflare Access policy**, not raw |
| 6 | Homebridge teardown | Delete after cutover, keep a documented record (this file) + a Longhorn snapshot |
| — | Cutover style | Parallel run. Host ports do not collide: Homebridge `8581`/`51333` vs HA `8123`/`21063` |
| — | Manifest style | Raw manifests + Kustomize, same as `my-apps/homebridge` and `my-apps/adguard-home` |
| 7 | Aqara Hub M2 path | **HomeKit Controller** — HA pairs to the M2 as a second HomeKit controller, the same protocol Apple Home already uses. No hardware, no sensor re-pairing. Rejected: Zigbee USB coordinator (needs USB passthrough, explicitly ruled out) and Aqara cloud/HACS (unnecessary cloud dependency for 5 sensors) |
| 8 | Solar inverter integration | **`huawei_solar`** (core, local Modbus TCP) — the dongle is LAN-reachable, no cloud needed |
| 9 | Mitsubishi AC integration | **MELCloud** (core, cloud) — Wi-Fi adapter + MELCloud account already exist, zero hardware changes. CN105/ESPHome local mod noted as a possible future upgrade, not required to start |
| — | Companion services (MQTT / Zigbee2MQTT / ESPHome) | **Not needed** — all three integrations above are core HA, reachable from the existing `hostNetwork` pod. No new Deployments |
| — | USB device passthrough | **Rejected** — no physical device will be passed into any pod |

---

## Device inventory

| Source | Device | Target in HA | Confidence |
|---|---|---|---|
| `homebridge-xiaomi-smart-plug` ×2 | Mi Smart Plug @ `192.168.0.30`, `192.168.0.31` | **Xiaomi Miio** (core, local, reuses existing IP + token) | High |
| `XiaomiZhimiHeaterMc2` | Smartmi heater `zhimi.heater.mc2a` @ `192.168.0.50` | **Xiaomi Miio** core; fall back to HACS `xiaomi_miot` if the model is rejected | Medium |
| `TuyaWebPlatform` | 2 Smart Life switches | **Tuya** (core, cloud) | High |
| `TuyaIR` | Tuya IR blaster | **Dropped — not actually in use**, no migration needed | n/a |
| Direct HomeKit pairing (Apple Home) | Aqara Hub M2 — 5 sensors/buttons | **HomeKit Controller** (core) — HA joins as a second HomeKit controller alongside Apple Home | Medium — see risk below |
| None (new) | Huawei/FusionSolar inverter + dongle (LAN-reachable) | **`huawei_solar`** (core, local Modbus TCP to the dongle's IP) | High, pending Modbus TCP enabled on the dongle |
| None (new) | Mitsubishi ducted AC (Wi-Fi adapter already MELCloud-paired) | **MELCloud** (core, cloud) | High |

Device IPs and miIO tokens live in the Homebridge `config.json` backup, **not in this repo**.
Solar serials and MELCloud credentials are likewise never stored here — like every
other integration, they live in HA's `.storage` on the PVC.

> **Risk — Aqara multi-controller pairing**: HomeKit's spec allows an accessory to
> have multiple paired controllers, so HA and Apple Home pairing to the M2
> simultaneously *should* work. If the hub refuses the second pairing, the fallback
> is to unpair it from Apple Home, pair it to HA only, then re-expose those 5
> entities to Apple Home through HA's own HomeKit Bridge in Phase 3 — the same path
> already planned for the Xiaomi/Tuya devices. Test this in Phase 2 before assuming
> either way.

---

## What was done (Phase 1)

Created `my-apps/home-assistant/`. Argo CD picks it up automatically via the git
directory generator in [`my-apps/myapplications-appset.yaml`](../my-apps/myapplications-appset.yaml)
— no ApplicationSet change was needed.

| File | Purpose |
|---|---|
| `namespace.yaml` | `home-assistant` namespace |
| `pvc.yaml` | `home-assistant-config`, Longhorn, RWO, 5Gi |
| `configuration.yaml` | HA base config (not a k8s resource — consumed by `configMapGenerator`) |
| `deployment.yaml` | HA `2026.7.4`, `hostNetwork`, `strategy: Recreate`, init container, probes |
| `service.yaml` | ClusterIP 80 → 8123 |
| `httproute.yaml` | `homeassistant.lan` → `gateway-internal` (`https` listener) |
| `certificate.yaml` | Self-signed cert via `selfsigned-cluster-issuer` |
| `kustomization.yaml` | Resources + `configMapGenerator` for `configuration.yaml` |

### Design notes

- **Init container is not optional.** HA only auto-creates `automations.yaml`,
  `scripts.yaml`, `scenes.yaml` and `themes/` when it generates a fresh
  `configuration.yaml`. Since ours is supplied read-only, HA would fail to start on
  the `!include` lines and the UI automation editor would have nothing to write to.
  The init container `touch`es them idempotently on the PVC.
- **`trusted_proxies` is mandatory.** Without it HA rejects requests coming through
  the Cilium Gateway and the Cloudflare tunnel with "invalid request". Configured for
  the node IP, the gateway LB IP and the k3s pod CIDR (`10.42.0.0/16`).
- **`configMapGenerator` hash suffix** means editing `configuration.yaml` changes the
  ConfigMap name, which rolls the Deployment. Without it a config change would need a
  manual pod restart, because `subPath` mounts never receive ConfigMap updates.
- **`strategy: Recreate`** — required for the ReadWriteOnce Longhorn volume, same as
  every other stateful app in this repo.

### Verified locally

```bash
kubectl kustomize my-apps/home-assistant
```

Renders cleanly; the Deployment volume correctly references the hashed ConfigMap name.

---

## What is missing

### Phase 0 — Prep (do before pushing)

- [ ] **Rotate the Tuya / Smart Life account password and the Tuya IoT API secret.**
      They were exposed in plaintext while planning this migration.
- [ ] Longhorn snapshot of the `homebridge-config` volume.
- [ ] Copy the Homebridge `config.json` off the volume to a safe location outside the repo.
- [ ] Screenshot every room, scene and automation in the Apple Home app — re-pairing
      loses all of it and there is no export.
- [ ] Log into the Huawei dongle's local web UI and enable **Modbus TCP** (disabled
      by default), note its LAN IP for Phase 2.
- [ ] Confirm the existing MELCloud app login still works — used directly in HA's
      MELCloud integration, never stored in this repo.

### Phase 1 — Deploy

- [ ] Push the branch and let Argo CD sync.
- [ ] `kubectl get app home-assistant -n argocd -w`
- [ ] `kubectl -n home-assistant get pod -w` — first boot takes 1–3 minutes.
- [ ] Confirm `homeassistant.lan` resolves to `192.168.0.35` (the `*.lan` AdGuard rewrite should already cover it).
- [ ] Open `https://homeassistant.lan`, complete onboarding, create the owner account.
- [ ] **Enable MFA immediately.**

### Phase 2 — Integrations

Add via *Settings → Devices & Services → Add Integration*. Credentials land in
`/config/.storage` on the PVC and never touch git.

- [ ] Xiaomi Miio — plug @ `192.168.0.30` (IP + token from the config.json backup)
- [ ] Xiaomi Miio — plug @ `192.168.0.31`
- [ ] Xiaomi Miio — heater @ `192.168.0.50`. **Open question**: whether the core
      integration supports `zhimi.heater.mc2a`. If the config flow rejects it, add
      HACS + `xiaomi_miot` — that needs an init container to seed
      `/config/custom_components`, which is not written yet.
- [ ] Tuya — 2 Smart Life switches via the app user-code / QR flow
- [ ] Aqara Hub M2 — add **HomeKit Controller**, pair using the hub's existing
      HomeKit code. Verify all 5 sensors/buttons show up as entities. If pairing is
      refused, see the risk note in Device inventory.
- [ ] Huawei Solar — add **`huawei_solar`**, point it at the dongle's LAN IP
      (Modbus TCP, default port 6607).
- [ ] Mitsubishi AC — add **MELCloud**, sign in with the existing account.
- [ ] Verify every entity actually toggles from the HA UI **before** touching HomeKit

### Phase 3 — HomeKit Bridge

- [ ] Enable the HomeKit Bridge integration with an **explicit entity include-filter**
      (do not bridge everything HA auto-creates).
- [ ] **If** the Aqara M2 refused a second controller pairing in Phase 2, include its
      5 entities in this filter too — same treatment as Xiaomi/Tuya.
- [ ] Pair the new bridge in the Apple Home app.
- [ ] Rebuild rooms, scenes and automations. Reuse the **exact old accessory names**
      so existing Siri phrases keep working.
- [ ] Test from the HomePod specifically, not just the phone.

### Phase 4 — Decommission Homebridge

- [ ] Remove the Homebridge bridge from the Apple Home app.
- [ ] Confirm the Longhorn snapshot from Phase 0 exists — deleting the Argo CD app
      **prunes the PVC**.
- [ ] Delete `my-apps/homebridge/`.
- [ ] Remove the `homebridge.pascualgrau.com` entry from
      [`infrastructure/networking/cloudflared/config.yaml`](../infrastructure/networking/cloudflared/config.yaml).
- [ ] Update [`docs/architecture.md`](architecture.md): drop Homebridge from the
      `my-apps/` tree listing, add Home Assistant.

### Phase 5 — Public access + hardening

- [ ] Create the Cloudflare Access policy for `homeassistant.pascualgrau.com` **first**.
- [ ] Only then add the tunnel ingress entry:
      `http://home-assistant.home-assistant.svc.cluster.local:80`.
- [ ] Confirm `trusted_proxies` covers the cloudflared pod IPs.
- [ ] Re-check MFA and `ip_ban_enabled`.

> Adding the tunnel hostname before the Access policy exists would publish the HA
> login page to the internet. Order matters.

---

## Rollback

Nothing is destructive until Phase 4. Up to that point Homebridge keeps running
untouched and still serves the Apple Home app. To abort:

```bash
# remove the HA app; Homebridge is unaffected
rm -rf my-apps/home-assistant
```

Then push — Argo CD prunes the namespace, Deployment and PVC.

---

## Open questions

1. Does the core `xiaomi_miio` integration support `zhimi.heater.mc2a`? Determines
   whether HACS is needed (decision #4).
2. Will the Aqara Hub M2 accept a second simultaneous HomeKit controller pairing
   (HA alongside Apple Home)? See the risk note in Device inventory for the fallback.

n8n (`agents/platform/n8n`) is scoped to the agent platform only and is not part of
this migration — HA's own automation engine is the sole automation layer for
smart-home devices.
