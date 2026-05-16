# Agent Memory Architecture

Memory system for `agent-api`. All phases implemented.

**Core principle**: Never store everything in the context window — only inject what's needed at runtime. Small context + selective retrieval + aggressive compression + structured storage.

---

## Memory Layers

| Layer | Technology | Storage | Scope |
|-------|-----------|---------|-------|
| Short-term (working memory) | LangGraph checkpointer | PostgreSQL | Per thread |
| Conversation summary | LangGraph state + GPT-4o-mini | PostgreSQL (via checkpointer) | Per thread |
| Long-term facts | Mem0 OSS (embedded, not a server) | PostgreSQL + pgvector | Per user × per agent |
| Semantic retrieval | Mem0 hybrid search (semantic + BM25) | pgvector embeddings | Per user × per agent |
| Response cache | Redis | Redis | Per agent + context hash |
| Memory lifecycle | n8n scheduled workflows | — | Per user × per agent |

---

## Context Assembly (per LLM call)

```
┌─────────────────────────────────────────────────────┐
│ SYSTEM PROMPT (~250 tokens, fixed)                  │
├─────────────────────────────────────────────────────┤
│ RETRIEVED MEMORIES (Mem0, max 500 tokens)           │
│ "User prefers concise answers. Name is Joan."       │
├─────────────────────────────────────────────────────┤
│ CONVERSATION SUMMARY (max 400 tokens)               │
│ "Earlier, user asked about K3s and ArgoCD..."       │
├─────────────────────────────────────────────────────┤
│ RECENT MESSAGES (last K raw)                        │
│   fast/ds-fast: max 2000-3000 tokens                │
│   ds-reasoning/expert: max 5000-6000 tokens         │
├─────────────────────────────────────────────────────┤
│ CURRENT MESSAGE (uncapped)                          │
└─────────────────────────────────────────────────────┘
```

Priority trimming order when over budget: oldest recent messages → summary → memories.

---

## Graph Flow

```
classify → retrieve_memories → route_by_complexity
  → respond_{trivial|simple|complex|reasoning|expert}
  → store_memories → maybe_summarize → END
```

---

## Implementation: Phase by Phase

### ✅ Phase 1 — Conversation Summarization

**File**: `agent-api/src/agents/personal_assistant.py`

- `AgentState` has `summary: str` field (persisted by checkpointer)
- `maybe_summarize` node: triggers when `len(history) > SUMMARY_THRESHOLD` (20 messages)
- Summarizes oldest messages with GPT-4o-mini, keeps last `KEEP_RECENT=6` raw
- Token counting via `tiktoken` before every context assembly
- Only `respond_*` nodes write to `history` — classify node never appends

### ✅ Phase 2 — Long-Term Memory via Mem0

**Files**: `agent-api/src/memory.py`, `agents/platform/postgresql/`

- Mem0 runs **embedded** (in-process library, not a separate server) — `Memory.from_config()`
- pgvector extension enabled on the `agents` PostgreSQL database; Mem0 creates its own `mem0_memories` table
- `retrieve_memories` node: called before LLM response; uses `mem.search(query, filters={"user_id": ..., "agent_id": ...})`
- `store_memories` node: called after LLM response; uses `mem.add(messages, user_id=..., agent_id=...)`
- Memory scoped by `user_id` (Telegram user ID) + `agent_id` (e.g. `assistant`) — fully isolated
- Embeddings: `text-embedding-3-small` (1536 dims); extraction LLM: GPT-4o-mini

**Known API asymmetry** (mem0ai library):
- `search()` → requires `filters={"user_id": ..., "agent_id": ...}`
- `add()` → uses top-level kwargs `user_id=..., agent_id=...`
- `get_all()` → requires `filters={"user_id": ..., "agent_id": ...}`

**Container constraint**: `readOnlyRootFilesystem: true` → `HOME=/tmp` env var required so mem0 can write `~/.mem0` config dir.

### ✅ Phase 3 — Cache Layer + Context Engineering

**File**: `agent-api/src/cache.py`

- Redis async response cache (`redis.asyncio`)
- Cache key: SHA-256 of `(agent_id, user_id, message.strip(), tier)` — keyed per user
- TTLs: `fast`→1h, `ds-fast`→5min, `ds-reasoning`→2min, `expert`→1min
- Password passed as separate kwarg (`password=settings.redis_password`) — never embedded in the URL (avoids `urllib.parse` failures with special characters)
- `_respond()` checks cache before LLM call; stores result after

**Memory quality filter** (`store_memories`):
- `_is_worth_storing(human_text)` heuristic — skips chit-chat, only stores turns containing signal keywords (`"my name"`, `"i prefer"`, `"we decided"`, `"from now on"`, etc.)

### ✅ Phase 4 — Memory Lifecycle

**Files**: `agent-api/src/lifecycle.py`, `agent-api/src/main.py`, `agent-api/workflows/memory-lifecycle.json`

Three admin HTTP endpoints on agent-api (called by n8n, not in the request path):

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/admin/memory/compact` | POST | Merge duplicate/overlapping memories via GPT-4o-mini |
| `/admin/memory/expire` | POST | Delete memories not updated in `stale_days` (default: 90) |
| `/admin/memory/stats` | GET | Return total count, avg age, stale count |

n8n workflow `memory-lifecycle.json` triggers:
- **Daily** (`0 3 * * *`) → compaction for each user+agent pair
- **Monthly** (`0 4 1 * *`) → expiry for each user+agent pair

To add a new user to lifecycle jobs, edit the `pairs` array in both Code nodes in the n8n workflow.

---

## Rules

**Always**:
- Retrieve instead of preload
- Summarize before trimming
- Count tokens before assembling context
- Scope memory by `user_id` + `agent_id`
- Filter what gets stored (decisions, facts, preferences — not chit-chat)

**Never**:
- Dump full history into prompt
- Let memory grow unbounded
- Mix unrelated sessions in retrieval
- Skip token budget enforcement
- Store transient reasoning or classification outputs

---

## Verification

```bash
# Long-term memory recall (cross-thread)
curl -s -X POST http://agent-api.lan/agents/assistant/invoke \
  -d '{"message":"My name is Joan and I prefer concise answers","thread_id":"mem-1","user_id":"user-joan"}' \
  -H "Content-Type: application/json"

# New thread — should still recall
curl -s -X POST http://agent-api.lan/agents/assistant/invoke \
  -d '{"message":"What do you know about me?","thread_id":"mem-2","user_id":"user-joan"}' \
  -H "Content-Type: application/json"

# Cache hit — second call should be instant
curl -s -X POST http://agent-api.lan/agents/assistant/invoke \
  -d '{"message":"What is the capital of France?","thread_id":"cache-test","user_id":"user-joan"}' \
  -H "Content-Type: application/json"

# Memory stats
curl -s "http://agent-api.lan/admin/memory/stats?user_id=user-joan&agent_id=assistant" | jq

# Compact
curl -s -X POST http://agent-api.lan/admin/memory/compact \
  -d '{"user_id":"user-joan","agent_id":"assistant"}' \
  -H "Content-Type: application/json" | jq
```
