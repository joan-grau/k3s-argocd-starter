## 1. Phase 0 — Prep

- [ ] 1.1 Create (or reuse) an OpenAI platform API key; set a monthly usage
      budget/alert in the OpenAI dashboard.
- [ ] 1.2 Confirm the final "interactive devices only" entity list from the
      HomeKit Bridge phase (`migrate-homebridge-to-home-assistant` Phase 3) —
      this change reuses the same set for Assist exposure.

## 2. Phase 1 — Conversation agent

- [ ] 2.1 Add the **OpenAI Conversation** integration (Settings → Devices &
      Services → Add Integration), paste the API key.
- [ ] 2.2 Set its instructions/system prompt to explicitly ask for concise,
      speakable answers (not long written-style responses).
- [ ] 2.3 Enable its Assist/LLM API tool-calling option so it can query/control
      exposed entities (exact label may vary by HA version — see design.md
      Open Questions).
- [ ] 2.4 Set it as the conversation agent for a (new or existing) Assist
      pipeline in Settings → Voice Assistants.
- [ ] 2.5 Set that pipeline's "Expose" list to the interactive-devices set
      from task 1.2.
- [ ] 2.6 Test in the HA UI (Assist chat bubble) with one general-knowledge
      question and one device-control question, before touching the HomePod.

## 3. Phase 2 — HA-side webhook bridge

- [ ] 3.1 Create a new automation with a **webhook trigger**; note the
      generated webhook_id/URL (this is the effective shared secret).
- [ ] 3.2 Action: call the `conversation.process` service, passing the
      webhook payload's text as the conversation input.
- [ ] 3.3 Return the conversation's reply text as the automation's response to
      the webhook caller.
- [ ] 3.4 Test the webhook directly from a LAN machine (curl/Postman) with a
      sample question before wiring up the Shortcut.

## 4. Phase 3 — Shortcut + Siri phrase

- [ ] 4.1 Create a new Shortcut: Dictate Text → Get Contents of URL (POST to
      the webhook URL, body = dictated text) → Speak Text (the response).
- [ ] 4.2 Add the Shortcut to Siri with a distinct custom phrase (e.g. "Ask
      Jarvis") as a personal automation.
- [ ] 4.3 Confirm the automation is enabled/available for the HomePod
      specifically (not just the iPhone) — see design.md Open Questions.
- [ ] 4.4 Test end-to-end from the HomePod hardware: a general-knowledge
      question.
- [ ] 4.5 Test end-to-end from the HomePod hardware: a device-control question
      from the exposed set.

## 5. Phase 4 — Hardening / verification

- [ ] 5.1 Confirm the webhook is reachable only on the LAN, not via the public
      Cloudflare Tunnel ingress (`infrastructure/networking/cloudflared`).
- [ ] 5.2 Confirm the OpenAI usage/budget alert from task 1.1 is active.
- [ ] 5.3 Write `docs/runbooks/homepod-conversational-ai.md` capturing the
      Shortcut structure, the Siri phrase, and the webhook rotation steps —
      none of this is git-trackable (Shortcut lives in iCloud, webhook_id is a
      secret), so this is the only durable record.
