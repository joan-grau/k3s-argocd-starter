# Agent Platform Plan

GitOps-managed agent platform built on top of the K3s cluster. Workflow-first, approval-gated, external LLMs only.

---

## Architecture Decisions

- **Hosting model**: External public LLMs — cluster is CPU-only, local inference is not the bottleneck
- **Operating mode**: Both interactive (Telegram) and background (n8n cron jobs)
- **Risk posture**: Approval-gated actions only — no fully autonomous external side effects in production
- **Rollout strategy**: Shared platform first, then one bounded low-risk agent, then higher-trust integrations
- **Secret management**: Bitnami Sealed Secrets — API keys never in plaintext git

**Excluded scope**: GPU enablement, self-hosted LLM inference, autonomous emailing or trading, broad multi-agent coordination.

---

## Platform Stack

| Component | Technology | Location | Purpose |
|-----------|-----------|----------|---------|
| Workflow engine | n8n | `agents/platform/n8n/` | Cron, webhooks, Telegram, approval loops |
| Agent runtime | FastAPI + LangGraph | `agents/platform/agent-api/` | LLM reasoning, tool execution |
| State store | PostgreSQL 16 + pgvector | `agents/platform/postgresql/` | Checkpointer, Mem0 memories, n8n DB |
| Cache | Redis 7 | `agents/platform/redis/` | Response cache, session locks |
| Secrets | Bitnami Sealed Secrets | `infrastructure/controllers/sealed-secrets/` | Encrypted secrets in git |

### Services

| Service | URL | Access |
|---------|-----|--------|
| n8n | `n8n.lan` | LAN only |
| agent-api | `agent-api.lan` | LAN only |
| PostgreSQL | `postgresql.postgresql.svc.cluster.local:5432` | In-cluster |
| Redis | `redis.redis.svc.cluster.local:6379` | In-cluster |

---

## Rollout Phases

### ✅ Phase 1 — Agents governance lane
Dedicated Argo CD project (`agents`) with ApplicationSet scanning `agents/platform/*` and `agents/domain/*`. Sync wave 2 (after monitoring). Separate project keeps agent credentials isolated from `my-apps`.

### ✅ Phase 2 — Secret and state foundations
Sealed Secrets controller deployed. PostgreSQL and Redis provisioned with Longhorn PVCs and `Recreate` strategy. pgvector extension enabled on the `agents` database.

### ✅ Phase 3 — Orchestration and interaction layer
n8n deployed and connected to PostgreSQL. Telegram bot configured as first notification and interaction channel. Webhook URL: `https://n8n.pascualgrau.com/`.

### ✅ Phase 4 — Agent service boundary (agent-api)
FastAPI + LangGraph service with multi-tier LLM routing (GPT-4o-mini fast, DeepSeek-V3 complex, DeepSeek-R1 reasoning, Claude Opus expert). Personal assistant agent with full memory stack implemented (see [memory-architecture.md](memory-architecture.md)).

### ✅ Phase 5 — Observability and guardrails
- `agent-api` instrumented with Prometheus: LLM latency (p50/p95 by tier), token counters, cache hit/miss rate, memory op latency
- ServiceMonitors for `agent-api` and `n8n`; both active targets in Prometheus
- Per-namespace ResourceQuotas: agent-api, n8n, postgresql, redis
- Longhorn `RecurringJob` daily snapshots (retain 7) on postgresql and redis PVCs
- Grafana "Agent Platform" dashboard: LLM Performance, Cache, Memory/Mem0, n8n Workflows, HTTP API rows — all showing live data

### ⬜ Phase 6 — First domain agent: Finance Advisor
- **Data**: yfinance (free, no API key) — stocks, ETFs, crypto, multi-exchange
- **Watchlist**: `watchlist.json` in the agent's private workspace — managed by the agent via workspace file tools
- **Tools**: `get_quote`, `get_technical_indicators` (RSI/MA20/MA50), `get_daily_summary` (batch from workspace watchlist)
- **Agent**: `src/agents/finance.py` — ReAct (ToolNode) graph, keyword-based tier routing (fast / ds-fast / ds-reasoning)
- **Daily summary**: n8n cron 08:00 CET weekdays → `POST /agents/finance/invoke` → Telegram
- **Interactive**: Telegram router updated with finance intent detection → routes finance queries to `/agents/finance/invoke`
- **Scope**: Fully read-only. No broker integration. Portfolio tracking deferred to Phase 6b.

---

## Agent API — LLM Tier Routing

| Tier | Model | Use case |
|------|-------|---------|
| `fast` | GPT-4o-mini | Trivial, simple factual |
| `ds-fast` | DeepSeek-Chat | Complex (code, analysis, planning) |
| `ds-reasoning` | DeepSeek-Reasoner | Chain-of-thought reasoning |
| `expert` | Claude Opus 4-7 | Nuanced judgment, creative synthesis |

Classification happens in the `classify` node before routing. Each tier has its own Redis cache TTL (fast: 1h, ds-fast: 5min, ds-reasoning: 2min, expert: 1min).

---

## n8n Workflow Inventory

| Workflow file | Trigger | Purpose |
|--------------|---------|---------|
| `telegram-agent-router.json` | Telegram webhook | Routes Telegram messages to agent-api |
| `memory-lifecycle.json` | Daily + monthly cron | Compact and expire long-term memories |

---

## Adding a Domain Agent

1. Create `agents/domain/{agent-name}/` with standard K8s manifests (namespace, deployment, service, httproute, sealedsecret)
2. Register the agent in `agents/platform/agent-api/configmap.yaml` under `agents:` — set `memory: true` for production agents
3. Implement the agent in `agent-api/src/agents/{agent_name}.py` using the shared baseline:
   ```python
   from src.agents.base import BASE_TOOLS, build_agent_graph
   # from src.tools.my_tools import tool_a, tool_b  # add domain-specific tools if needed

   SYSTEM_PROMPT = "You are a ..."
   TOOLS = [*BASE_TOOLS]  # or [tool_a, tool_b, *BASE_TOOLS]

   builder = build_agent_graph(agent_id="my_agent", system_prompt=SYSTEM_PROMPT, tools=TOOLS)
   graph = builder.compile()
   ```
   The agent inherits automatically: LLM 5-tier routing, Mem0 long-term memory, Redis cache, Prometheus metrics, rolling summarization, workspace tools, and schedule tools.
4. If the agent needs memory lifecycle jobs, add `{user_id, agent_id}` pairs to the `memory-lifecycle.json` n8n workflow
5. Add n8n workflow(s) for triggers (cron, Telegram intent, webhook, approval loops)
6. Commit — Argo CD auto-discovers and deploys

---

## Verification Checklist

- [ ] Argo CD shows agents project and ApplicationSet healthy; sync order: infra → monitoring → agents platform → domain agents
- [ ] Sealed secrets reconcile from git without plaintext credentials; pods receive runtime credentials
- [ ] PostgreSQL, Redis, n8n restart cleanly with Longhorn PVCs (no multi-attach errors)
- [ ] A scheduled n8n workflow sends a Telegram message and persists the result in PostgreSQL
- [ ] A dry-run finance workflow fetches market data, summarizes via LLM, stops at approval
- [ ] Prometheus scrapes agent metrics; Grafana shows workflow health and provider latency
- [ ] PostgreSQL backup / Longhorn snapshot restore test passes in a disposable namespace
