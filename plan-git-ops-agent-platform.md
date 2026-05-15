## Plan: GitOps Agent Platform

Use a workflow-first agent platform, not a local-model stack and not a free-form multi-agent mesh. Your current constraints point to external LLM APIs, approval-gated actions, and a shared platform for triggers, state, notifications, and audit. The best fit is a dedicated Argo CD-managed agents lane with shared services first, then narrow domain agents on top.

**Steps**
1. Phase 1: Add a dedicated agents governance lane.
Create a new Argo CD project for agents by extending /Users/joan.pascual/Repos/joan-grau/k3s-argocd-starter/infrastructure/controllers/argocd/projects.yaml. Add a new agents ApplicationSet modeled after /Users/joan.pascual/Repos/joan-grau/k3s-argocd-starter/my-apps/myapplications-appset.yaml instead of folding everything into my-apps. Reason: these workloads will hold more sensitive credentials and cross-cutting shared services than the current per-app layout. Use a sync wave after monitoring for the shared platform and a later wave for domain agents.
2. Phase 2: Add secret and state foundations. Depends on 1.
Introduce GitOps-safe secret handling before any agent credentials are committed. Recommended first choice for this homelab repo: Sealed Secrets under infrastructure/controllers so API keys never live in plaintext git. Deploy PostgreSQL plus Redis as shared agent platform data services using the same PVC, Longhorn, and Recreate patterns already used by stateful apps. Use PostgreSQL as the source of truth for agent configs, approval records, schedules, chat/session history, and audit logs. Defer a separate vector database; if retrieval becomes necessary later, extend PostgreSQL with pgvector rather than introducing another store immediately.
3. Phase 3: Add the orchestration and interaction layer. Depends on 2.
Deploy n8n as the workflow and integration hub because your first value comes from scheduled jobs, webhook triggers, external SaaS APIs, and approval loops more than from local model hosting. Use it for cron schedules, Telegram delivery, incoming webhooks, and human approval routing. Keep email, Shopify, and CJ Dropshipping as workflow connectors rather than hard-wiring them into a general assistant from day one.
4. Phase 4: Add a small code-first agent service boundary. Depends on 2 and 3.
Deploy a small Python API service for reasoning and tool execution, called by workflows when a decision or synthesis step is needed. Keep this service provider-agnostic so it can call external LLM APIs and return typed outputs for approval. Avoid a heavyweight multi-agent framework initially; define each future assistant as a bounded toolset plus prompts plus approval logic. This keeps the finance, Shopify, and fitness agents understandable, testable, and easier to govern through Argo CD.
5. Phase 5: Add observability, limits, and operational guardrails. Parallel with 4 after 2 exists.
Reuse the monitoring stack to add agent-specific metrics: workflow failures, approval backlog, provider latency, token usage, external API error rates, and schedule success/failure. Add per-namespace resource requests and limits, plus basic quotas so a broken workflow or noisy integration cannot starve the cluster. Add backup coverage for PostgreSQL and Redis before storing real personal or business data.
6. Phase 6: Define the first domain rollout after the platform. Depends on 3, 4, and 5.
Start with a read-heavy finance advisor rather than Shopify/email or health actions. It is the safest first proving ground: watchlists, price and indicator monitoring, daily summaries, Telegram alerts, and explicit approval before any side-effecting action. Once that path is stable, add the Shopify assistant with draft-only email replies and shipment triage. Keep the fitness advisor later because it introduces more personal data handling and long-term habit tracking requirements.
7. Phase 7: Keep scope boundaries explicit.
Do not add local model serving, GPUs, or model-weight storage in phase one. Do not allow autonomous email sending or store-wide Shopify changes in phase one. Do not add a separate message bus, vector database, or complex multi-agent coordination layer until the first bounded agent proves where those are actually needed.

**Relevant files**
- /Users/joan.pascual/Repos/joan-grau/k3s-argocd-starter/infrastructure/controllers/argocd/projects.yaml — extend with a dedicated agents AppProject and keep governance separate from the existing applications project.
- /Users/joan.pascual/Repos/joan-grau/k3s-argocd-starter/my-apps/myapplications-appset.yaml — reuse its directory-generator and sync policy pattern for a new agents ApplicationSet.
- /Users/joan.pascual/Repos/joan-grau/k3s-argocd-starter/infrastructure/infrastructure-components-appset.yaml — reference the infrastructure sync and app-of-apps pattern when placing a secrets controller.
- /Users/joan.pascual/Repos/joan-grau/k3s-argocd-starter/monitoring/monitoring-components-appset.yaml — reuse the existing monitoring lane and align new agent metrics with it instead of creating a second observability stack.
- /Users/joan.pascual/Repos/joan-grau/k3s-argocd-starter/my-apps/rsshub/kustomization.yaml — reference this as the template for multi-component workloads under one app.
- /Users/joan.pascual/Repos/joan-grau/k3s-argocd-starter/my-apps/homebridge/deployment.yaml — reference this for Recreate plus PVC-backed stateful deployment behavior.
- /Users/joan.pascual/Repos/joan-grau/k3s-argocd-starter/readme.md — update the architecture and deployment guide once the platform design is implemented.

**Verification**
1. Argo CD shows the new agents project and ApplicationSet healthy, and sync order remains infrastructure first, monitoring second, agents platform third, domain agents last.
2. Secrets can be reconciled from git without storing provider tokens in plaintext, and agent pods receive the expected runtime credentials.
3. PostgreSQL, Redis, and n8n restart cleanly with Longhorn-backed PVCs and do not hit multi-attach errors.
4. A scheduled heartbeat workflow sends a Telegram message, receives an approve or reject response, and persists the decision in PostgreSQL.
5. A dry-run finance workflow fetches external market data, summarizes it through the chosen LLM provider, records the recommendation, and stops at approval rather than taking action.
6. Prometheus scrapes the new platform metrics, Grafana shows workflow health and provider latency, and an alert fires on repeated workflow failure or stuck approvals.
7. A restore test confirms that at least PostgreSQL backups or Longhorn snapshots can recover platform state into a disposable namespace.

**Decisions**
- Hosting model: external public LLMs, because the cluster is CPU-only and local inference is not the current bottleneck.
- Operating mode: both interactive and background, with Telegram as the first interaction and notification channel.
- Risk posture: approval-gated actions only; no fully autonomous external side effects in the first release.
- Rollout strategy: foundational platform first, then one bounded low-risk agent, then higher-trust integrations.
- Included scope: GitOps-managed shared platform, secret management, workflow engine, state stores, approval channel, observability, and one pilot agent pattern.
- Excluded scope: GPU enablement, self-hosted LLM inference, autonomous emailing or trading, and a broad multi-agent coordination fabric.

**Further Considerations**
1. Secret management recommendation: choose Sealed Secrets now unless you already run a real secret manager; External Secrets only pays off once you have an external source of truth.
2. Data model recommendation: keep finance, commerce, and health data isolated by namespace and database schema so future agents do not implicitly share sensitive context.
3. Framework recommendation: prefer a small typed agent API service behind n8n rather than betting early on a general-purpose multi-agent framework. Add a stronger agent framework only if one real workflow becomes hard to express with this split.

---

## Plan: Agent Memory Architecture

### Core Principle

Never store everything in the context window — only inject what's needed at runtime. Bigger context ≠ better performance. The winning architecture is: **small context + selective retrieval + aggressive compression + structured storage**.

### Current State (Problems)

The current implementation uses a single flat memory layer: LangGraph's `AsyncPostgresSaver` checkpointer stores the full graph state per thread. The `_build_messages` function takes the last 20 raw messages and passes them verbatim into the context window.

| Problem | Impact |
|---------|--------|
| Naive truncation (last 20 messages, no summarization) | Early context permanently lost after ~10 exchanges |
| No compression (full message text replayed) | Long responses burn 10-15K tokens per request |
| No semantic retrieval (only recency matters) | Cannot recall relevant information from 50 messages ago |
| No cross-session memory (each thread_id isolated) | Agent cannot learn user preferences across conversations |
| No fact/chat distinction (flat message list) | "My name is Joan" treated identically to "What's 2+2?" |
| No memory filtering (everything stored) | Chit-chat and transient reasoning accumulate as noise |

### Target Architecture

```
                ┌──────────────────────┐
                │  User / Agent Input  │
                └─────────┬────────────┘
                          ↓
              ┌──────────────────────────┐
              │   Context Orchestrator   │
              │   (LangGraph node)       │
              │                          │
              │ Assembles the prompt:    │
              │  system_prompt           │
              │  + compressed summary    │
              │  + retrieved memories    │
              │  + recent messages (K)   │
              │  + current message       │
              │                          │
              │ Enforces token budget    │
              └─────────┬────────────────┘
                        ↓
      ┌──────────────────────────────────────────┐
      │ MEMORY SYSTEM (5 layers)                 │
      │                                          │
      │ 1. Short-term     LangGraph checkpointer │
      │                   (sliding window of K)  │
      │                                          │
      │ 2. Summarization  LLM-based compression  │
      │                   (rolling + session)     │
      │                                          │
      │ 3. Long-term      Mem0 OSS               │
      │                   (facts, preferences,   │
      │                    decisions, entities)   │
      │                                          │
      │ 4. Retrieval      Hybrid search via Mem0  │
      │    (RAG)          (semantic + BM25 +      │
      │                    entity linking)        │
      │                                          │
      │ 5. Cache          Redis response cache    │
      │                   + summary cache         │
      └──────────────────────────────────────────┘
                        ↓
                  LLM inference
```

### Design Decisions

- **Hybrid approach**: Mem0 OSS for long-term memory (fact extraction, semantic retrieval, entity linking), custom LangGraph nodes for short-term memory and summarization.
- **Multi-user**: Memory scoped by `user_id` + `agent_id` from day one. Each Telegram user gets isolated memory. Future-proofs for family/multi-user.
- **Isolated per agent**: Each agent (assistant, finance, fitness) owns its own memory store. No cross-agent memory sharing. Prevents context leaks between domains.
- **pgvector**: Extend existing PostgreSQL with `pgvector` extension for embeddings. No new service to deploy. Sufficient for homelab scale (< 1M memories).
- **Moderate summarization budget**: Summarize per session + periodic consolidation. Use fast tier (GPT-4o-mini) for summaries. No always-on background processing.
- **Knowledge base deferred**: Obsidian vault / RAG over personal docs is a future enhancement, not in scope now.

### Implementation Phases

#### Memory Phase 1: Conversation Summarization (code-only, no new infra)

**Goal**: Replace naive "last 20 messages" with intelligent compression. Bound the context window regardless of conversation length.

**Changes to `personal_assistant.py`**:

1. Add `summary` field to `AgentState` (string, persisted by checkpointer).
2. After each response, check if `len(history) > SUMMARY_THRESHOLD` (e.g., 10 message pairs / 20 messages).
3. If threshold exceeded, invoke fast-tier LLM to summarize the oldest messages into a compact paragraph.
4. Replace summarized messages with the summary string. Keep only the last K (e.g., 6) recent messages raw.
5. Update `_build_messages` (renamed to `build_context`) to assemble:
   - System prompt
   - `[Summary of earlier conversation: {summary}]` (if exists)
   - Last K raw messages
   - Current message

**Token budget enforcement**: The context builder must count tokens (via `tiktoken`) and trim if the assembled context exceeds a configurable limit (e.g., 4K tokens for fast tier, 8K for standard).

**Memory writing policy**: Only the response nodes write to history. The classify node does not append to history. Transient internal reasoning is never persisted.

**Graph structure**:
```
classify → route → respond_{simple|complex} → [if len(history) > threshold] → summarize → END
```

**Files changed**:
- `agent-api/src/agents/personal_assistant.py` — new `summarize` node, updated state, updated context builder
- `agent-api/pyproject.toml` — add `tiktoken` dependency

**Verification**:
- After 20+ exchanges, the history list stays bounded (< K recent + 1 summary)
- Agent can still reference facts mentioned 30 messages ago (via summary)
- Token usage per request stays under budget regardless of conversation length

#### Memory Phase 2: Long-Term Memory via Mem0 OSS (new platform service)

**Goal**: Extract and persist structured facts (preferences, decisions, entities) from conversations. Retrieve relevant memories at query time via hybrid search. Memory persists across sessions and threads.

**Infrastructure — deploy Mem0 OSS server**:

New directory: `agents/platform/mem0/` with:
- `namespace.yaml` (namespace: `mem0`)
- `deployment.yaml` — Mem0 server container (`mem0ai/mem0:latest`)
  - Connects to existing PostgreSQL (with pgvector extension)
  - Configurable LLM provider for memory extraction (use fast tier)
- `service.yaml` — ClusterIP on port 8080
- `httproute.yaml` — `mem0.lan` for debugging
- `kustomization.yaml`
- `sealedsecret.yaml` — Mem0 needs its own OpenAI key for embeddings (or share agent-api's)

**PostgreSQL changes**:
- Enable `pgvector` extension: `CREATE EXTENSION IF NOT EXISTS vector;`
- Mem0 creates its own tables (`memories`, `memory_entities`, etc.)
- Schema isolation: Mem0 uses a dedicated schema or database

**Agent-API integration — two new LangGraph nodes**:

1. **`retrieve_memories` node** (runs before respond):
   - Calls Mem0 API: `GET /memories/search?query={message}&user_id={user_id}&agent_id={agent_id}&top_k=5`
   - Returns relevant facts/memories
   - Context builder injects them as `[Relevant memories: ...]` block in system prompt
   - Enforce top_k ≤ 5 and token budget for memory block

2. **`store_memories` node** (runs after respond):
   - Calls Mem0 API: `POST /memories` with the conversation turn
   - Mem0 automatically extracts facts, preferences, decisions, entities
   - Mem0's internal memory filter decides what's worth persisting (not everything)

**Memory scoping**:
- `user_id`: derived from Telegram user ID (passed through n8n → agent-api)
- `agent_id`: the agent name (e.g., `assistant`, `finance`)
- Each agent+user combination has isolated memory

**Updated graph structure**:
```
classify → retrieve_memories → route → respond_{simple|complex} → store_memories → [if threshold] → summarize → END
```

**API changes to `main.py`**:
- Add `user_id` field to `InvokeRequest` (n8n passes Telegram user ID)
- Pass `user_id` into graph state

**Files changed**:
- `k3s-argocd-starter/agents/platform/mem0/` — new K8s manifests
- `k3s-argocd-starter/agents/platform/postgresql/` — init script for pgvector extension
- `agent-api/src/agents/personal_assistant.py` — new `retrieve_memories` and `store_memories` nodes
- `agent-api/src/main.py` — add `user_id` to request model
- `agent-api/src/memory.py` — new module: Mem0 API client (async HTTP calls)
- `agent-api/pyproject.toml` — add `httpx` for async Mem0 API calls

**Verification**:
- Tell the agent "My name is Joan and I prefer concise answers"
- Start a new thread (different `thread_id`, same `user_id`)
- Ask "What do you know about me?" — agent should recall name and preference
- Memory entries visible via Mem0 dashboard or API

#### Memory Phase 3: Cache Layer + Context Engineering (optimization)

**Goal**: Reduce redundant LLM calls and enforce strict context discipline.

**A. Redis response cache**:
- Before LLM call, compute semantic hash of (agent_id, user_id, message, recent_context)
- Check Redis for cached response (TTL: 1 hour for simple, 5 min for complex)
- Cache hit → return immediately, skip LLM call
- Expected savings: 30-50% reduction in LLM calls for repeated/similar questions

**B. Summary cache**:
- Cache the running summary in Redis (key: `summary:{agent_id}:{thread_id}`)
- Avoid re-reading full checkpointer state on every request
- Invalidate on new message

**C. Context builder hardening**:
- Strict token budget per section:
  - System prompt: fixed (~200 tokens)
  - Retrieved memories: max 500 tokens
  - Conversation summary: max 300 tokens
  - Recent messages: max 2000 tokens (fast tier) / 4000 tokens (standard tier)
  - Current message: uncapped (user input)
- Priority ordering: if over budget, trim in this order: oldest recent messages → summary → memories
- Add `tiktoken` counting to the context builder node

**D. Memory quality filter** (in `store_memories` node):
- Before sending to Mem0, classify the conversation turn:
  - Contains a decision, preference, fact, or outcome → store
  - Pure chit-chat, greeting, or transient reasoning → skip
- Use a lightweight heuristic (keyword matching) or fast-tier LLM call

**Files changed**:
- `agent-api/src/cache.py` — new module: Redis cache for responses and summaries
- `agent-api/src/context.py` — new module: token-aware context builder with budget enforcement
- `agent-api/src/agents/personal_assistant.py` — integrate cache checks, use new context builder

**Verification**:
- Ask the same question twice in 30 seconds → second response is instant (cache hit)
- Monitor Redis keys: `cache:response:*`, `cache:summary:*`
- Token usage per request stays within configured budgets
- Prometheus metrics: cache hit rate, tokens per request

#### Memory Phase 4: Memory Lifecycle (background maintenance)

**Goal**: Prevent memory degradation over time. Keep the memory store clean, current, and relevant.

**A. Periodic compaction** (n8n scheduled workflow):
- Daily job: call Mem0 API to list all memories for each user+agent
- Merge duplicate/overlapping memories (e.g., "likes coffee" + "prefers coffee in the morning" → "prefers coffee, especially in the morning")
- Use fast-tier LLM to detect and merge

**B. Staleness expiration**:
- Memories have a `last_accessed` timestamp (Mem0 tracks this)
- Monthly job: flag memories not accessed in 90 days
- Do not auto-delete — move to an "archived" state
- Agent can still retrieve archived memories if explicitly relevant

**C. Conflict resolution**:
- When Mem0 extracts a new fact that contradicts an existing one (e.g., "moved to Barcelona" vs. old "lives in Madrid"), Mem0's entity linking handles this via its ADD-only algorithm with temporal reasoning
- Monitor for conflicts via Mem0 API

**D. Memory health metrics** (Prometheus):
- Total memories per user per agent
- Memory growth rate
- Average retrieval relevance score
- Compaction events
- Cache hit rates

**Implementation**: All lifecycle jobs run as n8n workflows (cron-triggered), not as in-process code. This keeps the agent-api stateless and the maintenance observable via n8n execution logs.

**Files changed**:
- `agent-api/workflows/memory-compaction.json` — n8n workflow definition
- `k3s-argocd-starter/agents/platform/agent-api/configmap.yaml` — memory lifecycle config (thresholds, schedules)

### Summary: What Goes Where

| Layer | Technology | Storage | Scope |
|-------|-----------|---------|-------|
| Short-term (working memory) | LangGraph checkpointer | PostgreSQL | Per thread |
| Conversation summary | LangGraph state + fast-tier LLM | PostgreSQL (via checkpointer) | Per thread |
| Long-term facts | Mem0 OSS (extract + retrieve) | PostgreSQL + pgvector | Per user × per agent |
| Semantic retrieval | Mem0 hybrid search (semantic + BM25 + entity) | pgvector embeddings | Per user × per agent |
| Response cache | Redis | Redis | Per agent + context hash |
| Summary cache | Redis | Redis | Per thread |
| Memory lifecycle | n8n scheduled workflows + Mem0 API | — | Per user × per agent |

### Context Assembly (per LLM call)

```
┌─────────────────────────────────────────────────────┐
│ SYSTEM PROMPT (fixed, ~200 tokens)                  │
│ "You are a helpful personal assistant..."           │
├─────────────────────────────────────────────────────┤
│ RETRIEVED MEMORIES (from Mem0, max 500 tokens)      │
│ "User prefers concise answers. User's name is Joan. │
│  User is interested in finance and fitness."        │
├─────────────────────────────────────────────────────┤
│ CONVERSATION SUMMARY (max 300 tokens)               │
│ "Earlier, the user asked about K3s setup and we     │
│  discussed ArgoCD sync waves..."                    │
├─────────────────────────────────────────────────────┤
│ RECENT MESSAGES (last K raw, max 2000-4000 tokens)  │
│ Human: "What did we decide about the database?"     │
│ AI: "We chose PostgreSQL with pgvector..."          │
│ Human: "And for caching?"                           │
│ AI: "Redis with TTL-based expiration..."            │
├─────────────────────────────────────────────────────┤
│ CURRENT MESSAGE                                     │
│ Human: "Remind me of my preferences"                │
└─────────────────────────────────────────────────────┘
Total budget: ~4K tokens (fast) / ~8K tokens (standard)
```

### Rules (enforced in code)

**Always**:
- Retrieve instead of preload
- Summarize before trimming
- Count tokens before assembling context
- Scope memory by user_id + agent_id
- Filter what gets stored (decisions, facts, preferences — not chit-chat)

**Never**:
- Dump full history into prompt
- Let memory grow unbounded
- Mix unrelated sessions in retrieval
- Skip token budget enforcement
- Store transient reasoning or classification outputs

### Rollout Order

| Phase | Depends on | New infra | Estimated LLM cost impact |
|-------|-----------|-----------|--------------------------|
| Phase 1: Summarization | None | None (code-only) | +5% (summary calls) but -30% (smaller context) |
| Phase 2: Mem0 long-term | Phase 1 | Mem0 server, pgvector | +10% (extraction + retrieval) |
| Phase 3: Cache + context | Phase 1 | None (uses existing Redis) | -30 to -50% (cache hits) |
| Phase 4: Lifecycle | Phase 2 | None (n8n workflows) | +2% (compaction LLM calls) |

Net effect after all phases: **~20-30% reduction in LLM costs** compared to current naive approach, with dramatically better memory quality and bounded context windows.