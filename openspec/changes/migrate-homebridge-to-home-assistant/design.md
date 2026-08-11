## Context

Homebridge (`my-apps/homebridge`) and AdGuard Home (`my-apps/adguard-home`)
already establish the pattern this migration follows: raw Kubernetes manifests
+ Kustomize, no Helm chart. Home Assistant needs `hostNetwork: true` for
HomeKit Bridge mDNS advertisement and Xiaomi/Tuya LAN discovery, which rules out
a few otherwise-convenient options (see Decisions below). The cutover is a
parallel run: Homebridge keeps serving the Apple Home app, untouched, until
Home Assistant's replacement integrations are verified working.

## Goals / Non-Goals

**Goals:**
- Every device currently bridged through Homebridge keeps working after cutover,
  under the exact same Apple Home accessory names
- Newly-added devices (solar inverter, AC, vacuum, camera) become first-class
  HA integrations, automatable from one place
- No plaintext credentials or device tokens enter this repo at any point
- A clean, low-risk rollback path exists until Homebridge is actually deleted

**Non-Goals:**
- Building automations themselves (this migration is about getting devices
  *into* HA, not about the automations that will eventually use them)
- Any change to the agent platform or its n8n instance
- USB device passthrough or companion services (MQTT/Zigbee2MQTT/ESPHome) — all
  three new integrations run inside HA itself, reachable from the existing
  `hostNetwork` pod

## Decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Pod networking | `hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet` — required for HomeKit Bridge mDNS advertisement and Xiaomi/Tuya LAN discovery |
| 2 | `configuration.yaml` ownership | GitOps — ConfigMap mounted read-only via `subPath`, generated with a hash suffix so edits roll the pod |
| 3 | Recorder database | SQLite on the PVC. **Do not** reuse the `agents/platform` PostgreSQL |
| 4 | HACS / custom components | **Installed** — pinned via a GitOps init container (`install-hacs`, HACS `2.0.5`) cloning into `/config/custom_components/hacs` on every pod start. No longer gated on the heater/vacuum fallback; available immediately for any device that needs it |
| 5 | Public access | Cloudflare Tunnel, password + MFA only — **no Cloudflare Access** (breaks the HA Companion App's native API/WebSocket calls, which can't complete Access's browser-based login redirect). Hardening: `ip_ban_enabled: true`, `login_attempts_threshold: 5`, MFA |
| 6 | Homebridge teardown | Delete after cutover, keep a documented record (this change) + a Longhorn snapshot |
| — | Cutover style | Parallel run. Host ports do not collide: Homebridge `8581`/`51333` vs HA `8123`/`21063` |
| — | Manifest style | Raw manifests + Kustomize, same as `my-apps/homebridge` and `my-apps/adguard-home` |
| 7 | Aqara Hub M2 path | **HomeKit Controller** — HA pairs to the M2 as a second HomeKit controller, the same protocol Apple Home already uses. No hardware, no sensor re-pairing. Rejected: Zigbee USB coordinator (needs USB passthrough, explicitly ruled out) and Aqara cloud/HACS (unnecessary cloud dependency for 5 sensors) |
| 8 | Solar inverter integration | **`huawei_solar`** (HACS, local Modbus TCP) — the dongle is LAN-reachable, no cloud needed |
| 9 | Mitsubishi AC integration | **MELCloud** (core, cloud) — Wi-Fi adapter + MELCloud account already exist, zero hardware changes. CN105/ESPHome local mod noted as a possible future upgrade, not required to start |
| — | Companion services (MQTT / Zigbee2MQTT / ESPHome) | **Not needed** — all three integrations above run inside HA (core or HACS), reachable from the existing `hostNetwork` pod. No new Deployments |
| — | USB device passthrough | **Rejected** — no physical device will be passed into any pod |
| 10 | Xiaomi devices integration path | **HACS `xiaomi_home`** (`XiaoMi/ha_xiaomi_home`, cloud, Mi account login) — accepted all devices: both plugs, heater `zhimi.heater.mc2a`, and Vacuum S20. Core `xiaomi_miio` fallback chain was not needed |
| 11 | Mi 360 camera path | **Unofficial RTSP firmware hack** + core **Generic Camera (RTSP)** — risk accepted, isolated as its own phase since it's a device-level change outside Kubernetes/GitOps entirely |
| 12 | Solar visualization | **Power Flow Card Plus** (HACS, Frontend/Dashboard category) — animated solar → battery → grid → home flow card. Installed via the HACS UI like any other HACS repo; lives on the PVC only, not git — same reproducibility gap HACS itself had before its `install-hacs` init container |

### Device inventory

| Source | Device | Target in HA | Confidence |
|---|---|---|---|
| `homebridge-xiaomi-smart-plug` ×2 | Mi Smart Plug @ `192.168.0.30`, `192.168.0.31` | **HACS `xiaomi_home`** (cloud, Mi account) — working ✓ | High |
| `XiaomiZhimiHeaterMc2` | Smartmi heater `zhimi.heater.mc2a` @ `192.168.0.50` | **HACS `xiaomi_home`** (cloud, Mi account) — working ✓, model accepted | High |
| `TuyaWebPlatform` | 2 Smart Life switches | **Tuya** (core, cloud) | High |
| `TuyaIR` | Tuya IR blaster | **Dropped — not actually in use**, no migration needed | n/a |
| Direct HomeKit pairing (Apple Home) | Aqara Hub M2 — 5 sensors/buttons | **HomeKit Controller** (core) — HA joins as a second HomeKit controller alongside Apple Home | Medium — see risk below |
| None (new) | Huawei/FusionSolar inverter + dongle (LAN-reachable) | **`huawei_solar`** (HACS, local Modbus TCP to the dongle's IP) | High — Modbus TCP already enabled |
| None (new) | Mitsubishi ducted AC (Wi-Fi adapter already MELCloud-paired) | **MELCloud** (core, cloud) | High |
| None (new) | Xiaomi Robot Vacuum S20 | **HACS `xiaomi_home`** (cloud, Mi account) — working ✓, no local token extraction needed | High |
| None (new) | Mi 360 security camera | Unofficial RTSP firmware hack + **Generic Camera (RTSP)** (core) | Low — no vendor-supported path, firmware-hack risk |

Device IPs and miIO tokens live in the Homebridge `config.json` backup, **not in
this repo**. Solar serials and MELCloud credentials are likewise never stored
here — like every other integration, they live in HA's `.storage` on the PVC.

## Risks / Trade-offs

> **Aqara multi-controller pairing**: HomeKit's spec allows an accessory to have
> multiple paired controllers, so HA and Apple Home pairing to the M2
> simultaneously *should* work. If the hub refuses the second pairing, the
> fallback is to unpair it from Apple Home, pair it to HA only, then re-expose
> those 5 entities to Apple Home through HA's own HomeKit Bridge — the same path
> already planned for the Xiaomi/Tuya devices. Test this before assuming either
> way.

> **Mi 360 firmware hack**: this is a device-level modification outside
> Kubernetes/GitOps entirely — no manifest or HA config mitigates it. It can
> brick the camera or break its Mi Home pairing. The camera has no dependency
> from any other integration in this plan, so worst case is simply losing the
> camera, not blocking the rest of the migration. Confirm the RTSP stream plays
> externally (VLC/ffprobe) before adding it to HA.

> **No Cloudflare Access in front of the public tunnel**: dropped because
> Access redirects to a browser-based login the HA Companion App can't
> complete, breaking remote app access entirely. The perimeter is HA's own
> auth only (password + MFA + `ip_ban_enabled` + `login_attempts_threshold`),
> weaker than Access + MFA would have been. Revisit if Cloudflare WARP
> (split-tunnel) or a VPN-based remote-access path is adopted later.

## Implementation notes (Phase 1)

Created `my-apps/home-assistant/`. Argo CD picks it up automatically via the git
directory generator in `my-apps/myapplications-appset.yaml` — no ApplicationSet
change was needed.

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

- **Init container is not optional.** HA only auto-creates `automations.yaml`,
  `scripts.yaml`, `scenes.yaml` and `themes/` when it generates a fresh
  `configuration.yaml`. Since ours is supplied read-only, HA would fail to
  start on the `!include` lines and the UI automation editor would have
  nothing to write to. The init container `touch`es them idempotently on the
  PVC.
- **`trusted_proxies` is mandatory.** Without it HA rejects requests coming
  through the Cilium Gateway and the Cloudflare tunnel with "invalid request".
  Configured for the node IP, the gateway LB IP and the k3s pod CIDR
  (`10.42.0.0/16`).
- **`configMapGenerator` hash suffix** means editing `configuration.yaml`
  changes the ConfigMap name, which rolls the Deployment. Without it a config
  change would need a manual pod restart, because `subPath` mounts never
  receive ConfigMap updates.
- **`strategy: Recreate`** — required for the ReadWriteOnce Longhorn volume,
  same as every other stateful app in this repo.
- **HACS via init container, not a manual/HA-UI download.** The `install-hacs`
  init container clones a pinned HACS tag (`2.0.5`) straight into
  `/config/custom_components/hacs` on every pod start, so the integration is
  reproducible from Git and survives PVC loss the same way the rest of the
  config does. Bump `HACS_VERSION` in `deployment.yaml` to upgrade. The HACS
  integration itself (GitHub device-code login) still has to be added once
  from *Settings → Devices & Services → Add Integration* after the pod
  restarts with the files in place — that login state lives in `.storage`
  like every other integration.

Verified locally:

```bash
kubectl kustomize my-apps/home-assistant
```

Renders cleanly; the Deployment volume correctly references the hashed
ConfigMap name.

## Rollback

Nothing is destructive until the Homebridge decommission phase. Up to that
point Homebridge keeps running untouched and still serves the Apple Home app.
To abort:

```bash
# remove the HA app; Homebridge is unaffected
rm -rf my-apps/home-assistant
```

Then push — Argo CD prunes the namespace, Deployment and PVC.

## Open questions

1. ~~Does the core `xiaomi_miio` integration support `zhimi.heater.mc2a`?~~
   **Resolved** — used HACS `xiaomi_home` (cloud) instead; heater accepted and
   working.
2. Will the Aqara Hub M2 accept a second simultaneous HomeKit controller
   pairing (HA alongside Apple Home)? See the risk note above for the
   fallback.
3. ~~Will the S20 respond to a local `xiaomi_miio`/`roborock` handshake?~~
   **Resolved** — HACS `xiaomi_home` (cloud) accepted the S20 directly; no
   local token extraction needed.
4. Does the Mi 360's exact hardware/firmware revision have a known, maintained
   RTSP hack? Must be confirmed before starting the camera phase.
