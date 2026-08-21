## 1. Add the Ring integration

- [x] 1.1 In Home Assistant, go to Settings → Devices & Services → Add
      Integration → **Ring**.
- [x] 1.2 Sign in with the Ring account (username/password) and complete the
      2FA verification code step.
- [x] 1.3 Confirm the Intercom appears as a device (Developer Tools → States).
      If the account has other Ring devices, note them but leave them alone —
      out of scope for this change.

## 2. Verify entities

- [x] 2.1 Confirm the expected entities exist and note their real entity IDs
      (don't assume names from documentation): one `button` (open door), one
      `event` (ring/unlock activity), two `number`s (intercom voice volume,
      intercom mic volume).
- [x] 2.2 Test the open-door button once and confirm the physical door
      relay/buzzer actually fires.
- [x] 2.3 Trigger a ring/unlock event and confirm the `event` entity updates in
      real time (not just on the ~60s poll) — confirms outbound TCP 5228 to
      Ring's realtime service isn't blocked. If it only updates on the slow
      poll, check `ufw status`/outbound rules on the node.

## 3. Apple Home / HomeKit Bridge exposure

- [x] 3.1 Add the `button`, `event`, and both `number` entities to the existing
      HomeKit Bridge's exposed-entities list (Settings → Devices & Services →
      HomeKit Bridge → Configure).
- [x] 3.2 Confirm all four show up as accessories in the Apple Home app.
- [x] 3.3 If the open-door `button` doesn't behave as a usable accessory in the
      Home app, create a `script`/`scene` helper wrapping it and expose that
      entity to HomeKit instead.

## 4. Wrap-up

- [x] 4.1 Confirm no automations were added (by design — see design.md
      Non-Goals); this change only brings the device into HA.
- [x] 4.2 If ring/unlock events are ever unstable later, check/clean up
      [Ring's Authorized Client Devices](https://account.ring.com/account/control-center/authorized-devices)
      before assuming something else broke (see design.md Risks).
