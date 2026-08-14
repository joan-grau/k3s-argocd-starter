## Why

Once Home Assistant is the single smart-home hub (`migrate-homebridge-to-home-assistant`),
the remaining gap is a general-purpose conversational assistant reachable from the HomePod
already in the house — not just fixed Siri phrases for device control, but free-form Q&A and,
optionally, natural-language device control, without waiting on Apple to open up Siri itself.

## What Changes

- Add Home Assistant's core **OpenAI Conversation** integration, configured as an Assist
  conversation agent with HA's LLM API enabled (native tool-calling), so it can query/control
  entities exposed to Assist — not just chat. Chosen over the HACS "Extended OpenAI
  Conversation" fork: HA 2024.8+ added native Assist/LLM API tool-calling to the core
  integration, which used to be Extended's only edge, so the core integration is now the
  lower-risk, officially-maintained option (same "prefer core over HACS unless core can't do
  it" pattern already used for other integrations in this repo)
- Expose only the interactive-device entity set to Assist — the same "interactive devices
  only" set curated for the HomeKit Bridge in Phase 3 of `migrate-homebridge-to-home-assistant`
  (plugs, heater, vacuum, AC, camera, Aqara sensors/buttons, solar switches) — excluding raw
  diagnostic sensors, so voice control and Apple Home stay consistent
- Bridge the HomePod to this agent with a custom Siri phrase: a Shortcuts personal automation
  that captures dictated speech, POSTs it to HA's `/api/conversation/process` endpoint (long-lived
  access token), and speaks the returned response back — e.g. "Hey Siri, ask Jarvis..." rather
  than Siri itself becoming ChatGPT, which Apple does not allow
- OpenAI API key stored the same way every other HA integration credential is in this repo:
  entered once via the HA UI config flow, persisted in `.storage` on the PVC, never in git
- No changes to `agents/platform` (agent-api, n8n) — this conversational agent is independent
  of the existing Telegram-facing personal assistant; both share the "external LLMs only, no
  self-hosted inference" posture but are otherwise separate stacks

## Capabilities

### New Capabilities

None. This is a homelab home-automation change with no documented external behavior contract
tracked as an OpenSpec capability in this repo — consistent with
`migrate-homebridge-to-home-assistant` and `add-tesla-solar-charging`, both of which also set
`skip_specs: true`. Same here.

### Modified Capabilities

None.

## Impact

- **Added**: HA "OpenAI Conversation" integration config (lives in HA's own `.storage`/config
  on the PVC, no new Kubernetes manifest or Argo CD app); a Shortcuts personal automation
  authored and stored on the HomePod/Apple ecosystem (iCloud), outside this repo — not GitOps,
  documented here as the historical record; a long-lived HA access token scoped to the
  Shortcut, stored in the Shortcut itself, never in git
- **Modified**: the `home-assistant` app's Assist-exposed entity list (Settings → Voice
  Assistants → Expose) — same entity set as the HomeKit Bridge's interactive-devices filter
- **Physical/manual**: OpenAI API key provisioning (platform.openai.com), HomePod-side
  Shortcut authoring (Apple ecosystem, not git-trackable), one-time Siri phrase setup
- **Not affected**: `agents/platform`, `my-apps/homebridge` (decommissioned via the other
  change), `add-tesla-solar-charging`
