## Context

See proposal.md - Why. Builds on `migrate-homebridge-to-home-assistant`, which is where
Home Assistant itself, its HomeKit Bridge, and the "interactive devices only" entity
curation already live:

- HA runs as a plain container Deployment in k3s (`my-apps/home-assistant/`), not Home
  Assistant OS/Supervised — same constraint the Tesla change already had to work around.
- Reachable two ways: `homeassistant.lan` (Cilium Gateway, LAN only) and
  `homeassistant.pascualgrau.com` (Cloudflare Tunnel, public, password + MFA). The HomePod
  never leaves the home network, so this change has no reason to touch the public path.
- Every integration credential in this HA instance (Xiaomi, Tuya, MELCloud, and now
  OpenAI) lives in `.storage` on the PVC, entered once via the HA UI, never in git.
- The "interactive devices only" entity set (plugs, heater, vacuum, AC, camera, Aqara
  sensors/buttons, solar switches — no raw diagnostic sensors) was confirmed for the
  HomeKit Bridge filter in the parent change's Phase 3. This change reuses the same set
  for Assist exposure, so voice control and Apple Home stay consistent.
- `agents/platform` (agent-api, n8n) is a separate, Telegram-facing personal-assistant
  stack with its own LangGraph routing and Mem0 memory. It shares this change's "external
  LLMs only, no self-hosted inference" posture but is otherwise untouched and unrelated.

## Goals / Non-Goals

**Goals:**
- A HomePod-reachable Siri phrase that answers free-form conversational questions
- The same phrase (or the underlying agent) can also control the interactive-devices set
  by voice, via natural language rather than fixed HomeKit phrases
- Keep the credential/config footprint consistent with how every other integration in
  this HA instance is already handled — nothing new in git

**Non-Goals:**
- Replacing Siri's own wake-word/speech recognition — Apple does not allow a third party
  to become Siri's engine; this is a bridge *alongside* Siri, not a replacement
- Long-term conversational memory (Mem0-style, recall across days/weeks) — HA Assist
  conversations are short-term only; wiring this into agent-api's memory stack is a
  possible future change, not this one
- Distinguishing which family member is speaking — HomePod doesn't expose per-speaker
  identity to Shortcuts/automations
- Any change to `agents/platform`, `my-apps/homebridge`, or `add-tesla-solar-charging`

## Decisions

| # | Decision | Choice |
|---|----------|--------|
| 1 | Conversation agent | **Core "OpenAI Conversation"** integration, with its Assist/LLM API tool-calling enabled. Rejected: HACS "Extended OpenAI Conversation" — its only remaining edge over core (since HA 2024.8 added native Assist/LLM API tool-calling to core) is fully custom function definitions beyond HA's own entities; not needed here, and core is officially maintained, lower risk |
| 2 | Voice-exposed device set | Reuse the **same "interactive devices only" set** curated for the HomeKit Bridge filter in `migrate-homebridge-to-home-assistant` Phase 3 (plugs, heater, vacuum, AC, camera, Aqara sensors/buttons, solar switches) — one mental model for "what's voice/HomeKit controllable", even though HomeKit Bridge and Assist Expose are two separate HA settings |
| 3 | HomePod trigger mechanism | **Shortcuts personal automation**: a custom Siri phrase (e.g. "Hey Siri, ask Jarvis...") triggers a Shortcut that dictates speech, calls Home Assistant, and speaks the reply back. Rejected: waiting on the HA Companion app's native Siri/App Intents support (no free-form dictation-to-arbitrary-backend today); dedicated voice-satellite hardware (e.g. Home Assistant Voice Preview Edition) — out of scope, the goal is to use the HomePod already in the house |
| 4 | Network path | **LAN only**, via `homeassistant.lan` — the HomePod never leaves the home network, so there is no reason to route conversational queries through the public Cloudflare Tunnel, and it avoids adding a new public attack surface |
| 5 | Shortcut authentication | A dedicated HA automation with a **webhook trigger** that calls the `conversation.process` service and returns the reply via the automation's response. Rejected: handing the Shortcut a full-scope Long-Lived Access Token direct to `/api/conversation/process` — a webhook_id is a single-purpose, independently-rotatable secret; a Long-Lived Access Token can do anything the HA account can do, a much bigger blast radius if the Shortcut (iCloud-synced) is ever exposed |
| 6 | Response playback | Shortcuts' native **"Speak Text"** action reading the webhook's response text — on-device TTS, no extra service |
| 7 | Conversation continuity | **Stateless**: a new conversation each invocation, no reused `conversation_id`. Matches a "one-off question" mental model and is the simplest to build; switching to a reused id for multi-turn follow-ups later is a Shortcut-only change, not a re-architecture |

## Risks / Trade-offs

> **Voice queries leave the house to OpenAI on every invocation.** → Mitigation: accepted,
> consistent with this repo's existing "external LLMs only" posture (agent-api already
> sends conversation content off-box); avoid sensitive topics through this channel, same
> as any cloud voice assistant.

> **OpenAI usage is billed per token to the user's own API key, uncapped by default.**
> → Mitigation: set a monthly budget/limit in the OpenAI platform dashboard.

> **A compromised Shortcut or iCloud account could invoke the webhook.** → Mitigation:
> the webhook_id is a long random secret and only reachable on the LAN; rotate by
> regenerating the webhook_id (and updating the Shortcut) if ever suspected leaked.

> **Core OpenAI Conversation's tool-calling is limited to entities exposed to Assist** —
> it cannot call arbitrary custom tools (e.g. agent-api's finance/memory functions).
> → Mitigation: accepted per Decision 1; revisit with HACS Extended or a direct
> agent-api bridge later if broader tool access is ever wanted.

> **HomePod Shortcuts/personal-automation support has historically had software-version
> quirks** (some versions lean on a nearby iPhone/iPad to trigger certain automations).
> → Mitigation: verify directly against the HomePod hardware/software in use (Migration
> Plan step 7) before relying on it daily; see Open Questions.

> **Assist's default reply style is tuned for short voice answers, not long essays.**
> → Mitigation: set the OpenAI Conversation integration's instructions/system prompt to
> explicitly ask for brief, speakable answers.

## Migration Plan

1. Add the OpenAI Conversation integration in the HA UI; paste the API key; set its
   instructions/system prompt for concise, speakable answers; enable its Assist/LLM API
   tool-calling option.
2. Set Assist's "Expose" list to the same interactive-devices set used for the HomeKit
   Bridge filter.
3. Build the wrapping HA automation: webhook trigger → `conversation.process` action →
   response returned to the caller.
4. Note the generated webhook URL (the effective shared secret).
5. Build the Shortcut: Dictate Text → Get Contents of URL (POST to the webhook, body =
   dictated text) → Speak Text (the response).
6. Assign a custom Siri phrase to the Shortcut as a personal automation; confirm it's
   available for the HomePod specifically, not just the phone.
7. Test end-to-end from the HomePod hardware directly — both a general-knowledge
   question and a device-control question from the exposed set.

**Rollback:** remove the OpenAI Conversation integration from Settings → Devices &
Services, delete the wrapping automation, delete the Shortcut. Nothing else in HA or the
cluster is touched — no PVC, Deployment, or other integration is affected.

## Open Questions

1. The exact HA UI label for enabling Assist/LLM API tool-calling on the OpenAI
   Conversation integration may differ slightly by HA version — confirm the exact option
   at implementation time; doesn't change the approach.
2. Whether this HomePod's specific software version triggers personal automations fully
   locally, or leans on a nearby iPhone/iPad — confirm in Migration Plan step 7. Fallback
   if not: trigger the same Shortcut from an iPhone's Siri instead of the HomePod
   directly; the conversational agent and automation side are unaffected either way.
