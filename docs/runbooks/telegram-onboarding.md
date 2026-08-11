# Telegram Bot & User Onboarding

This guide explains how to onboard a new Telegram bot and register users to grant them
access to an agent. It covers every field in the `telegram_bots` and `telegram_users`
tables, how to obtain all required IDs, and how the n8n workflow is generated automatically.

---

## How the system works

```
Telegram user → Bot (n8n Trigger) → POST /telegram/invoke
                                         │
                                   agent-api resolves
                                   (bot_id, chat_id) → user_id
                                         │
                                   dispatches to the agent
                                   assigned to this bot
```

- **`telegram_bots`** — one row per bot; maps a bot to an agent
- **`telegram_users`** — one row per (bot, user) pair; maps a Telegram identity to an internal user
- **n8n workflow** — generated from a template; contains no user data, just `bot_id`
- **Authorization** — happens in agent-api: if no row in `telegram_users` matches the incoming `(bot_id, chat_id)`, the request is rejected with `403`

---

## Step 1 — Create a Telegram bot

1. Open Telegram and start a chat with **@BotFather**
2. Send `/newbot` and follow the prompts (name + username)
3. BotFather returns a **bot token** — keep it, you need it for n8n

---

## Step 2 — Get the bot_id

The `bot_id` is the **numeric Telegram ID of the bot** (not the token). Retrieve it:

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getMe" | jq '.result | {id, username}'
```

Example response:
```json
{ "id": 8297575120, "username": "my_finance_bot" }
```

`id` is your `bot_id`. It never changes for the lifetime of the bot.

---

## Step 3 — Get the user's chat_id

The `chat_id` is the **numeric Telegram ID of the person** who will use the bot.

**Method A — via getUpdates** (requires the user to have sent a message to the bot first):

```bash
# 1. Have the user send any message to the bot (e.g. /start)
# 2. Then fetch updates:
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" \
  | jq '.result[] | {chat_id: .message.chat.id, from: .message.from.username}'
```

**Method B — via a userinfobot**:  
Have the user send a message to **@userinfobot** in Telegram — it replies with their numeric `id`.

> Note: if `getUpdates` returns empty, it means n8n's Telegram Trigger has already consumed the updates via polling. Use Method B or check past n8n execution logs (Telegram Trigger node → Executions tab → any entry → `message.chat.id`).

---

## Step 4 — Add the bot token as a GitHub Actions secret

1. Go to your `agent-api` repository → **Settings → Secrets and variables → Actions → New repository secret**
2. Name: must match the `token_secret` value in `bots.yaml` (e.g. `FINANCE_BOT_TOKEN`)
3. Value: the bot token from BotFather

The CI pipeline uses this secret to call the n8n Credentials API and create the
Telegram credential automatically. The token never appears in the repo or in n8n workflows.

---

## Step 5 — Add the bot to bots.yaml

Edit `agent-api/bots.yaml`:

```yaml
bots:
  - bot_id: "8297575120"          # numeric bot ID from getMe
    bot_name: "Finance Bot"        # human-readable; also used as n8n workflow name
    agent_id: "finance"            # must match a key in agents.yaml
    token_secret: "FINANCE_BOT_TOKEN"  # GitHub Actions secret name (holds the bot token)
```

Commit and push to `main` → GitHub Actions:
1. Reads the bot token from the GitHub secret
2. Creates (or finds) the Telegram API credential in n8n automatically
3. Renders the workflow JSON with the returned credential ID
4. Upserts the workflow in n8n

---

## Step 6 — Insert rows into the database

```bash
POD=$(kubectl get pod -n postgresql -o jsonpath='{.items[0].metadata.name}')

# Register the bot (one-time per bot)
kubectl exec -n postgresql $POD -- psql -U agents -d agents -c "
INSERT INTO telegram_bots (bot_id, bot_name, agent_id)
VALUES ('8297575120', 'Finance Bot', 'finance')
ON CONFLICT (bot_id) DO NOTHING;
"

# For the general assistant bot
kubectl exec -n postgresql $POD -- psql -U agents -d agents -c "
INSERT INTO telegram_bots (bot_id, bot_name, agent_id)
VALUES ('8330322737', 'Assistant Bot', 'assistant')
ON CONFLICT (bot_id) DO NOTHING;
"

# Register a user on a bot (one per user per bot)
kubectl exec -n postgresql $POD -- psql -U agents -d agents -c "
INSERT INTO telegram_users (bot_id, chat_id, user_id)
VALUES ('8297575120', '179128233', 'user-joan')
ON CONFLICT (bot_id, chat_id) DO NOTHING;
"

# Same user on the assistant bot
kubectl exec -n postgresql $POD -- psql -U agents -d agents -c "
INSERT INTO telegram_users (bot_id, chat_id, user_id)
VALUES ('8330322737', '179128233', 'user-joan')
ON CONFLICT (bot_id, chat_id) DO NOTHING;
"
```

---

## Database field reference

### `telegram_bots`

| Column | Type | Description |
|--------|------|-------------|
| `bot_id` | TEXT PK | Numeric Telegram bot ID (from `getMe`). Immutable for the lifetime of the bot. Used to correlate n8n workflows with DB rows. |
| `bot_name` | TEXT | Human-readable display name. Used in n8n as the workflow name and credential label. |
| `agent_id` | TEXT | Which agent handles all messages received by this bot. Must match a key in `agents.yaml` (e.g. `finance`, `assistant`). One bot = one agent. |

### `telegram_users`

| Column | Type | Description |
|--------|------|-------------|
| `bot_id` | TEXT FK → `telegram_bots.bot_id` | Which bot this authorization applies to. The same person must be registered separately for each bot they want to use. |
| `chat_id` | TEXT | Numeric Telegram ID of the person. Unique per person (not per device). Obtained via `getUpdates` or @userinfobot. |
| `user_id` | TEXT | Internal user identity used by agents for long-term memory and workspace isolation. Each agent gets a sandboxed workspace at `/workspace/{user_id}/{agent_id}/`. |

> `(bot_id, chat_id)` is the primary key — one user can be registered on multiple bots with the same or different `user_id`.

---

## Revoking access

```bash
# Remove a single user from a bot
kubectl exec -n postgresql $POD -- psql -U agents -d agents -c "
DELETE FROM telegram_users WHERE bot_id = '8297575120' AND chat_id = '123456789';
"

# Remove a bot entirely (also deletes all its users via CASCADE)
kubectl exec -n postgresql $POD -- psql -U agents -d agents -c "
DELETE FROM telegram_bots WHERE bot_id = '8297575120';
"
```

---

## Summary checklist

- [ ] Create bot via @BotFather → get token
- [ ] Get `bot_id` via `getMe`
- [ ] Get user's `chat_id` via `getUpdates` or @userinfobot
- [ ] Add bot token as GitHub Actions secret (named to match `token_secret` in bots.yaml)
- [ ] Add entry to `bots.yaml` → commit & push (credential + workflow auto-deployed)
- [ ] `INSERT INTO telegram_bots` (one per bot)
- [ ] `INSERT INTO telegram_users` (one per user per bot)
