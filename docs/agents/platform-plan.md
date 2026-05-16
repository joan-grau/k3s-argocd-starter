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

### ⬜ Phase 5 — Observability and guardrails
- Add agent-specific Prometheus metrics: workflow failures, approval backlog, LLM provider latency, token usage, cache hit rate
- Add per-namespace resource quotas so a broken workflow cannot starve the cluster
- Add PostgreSQL and Redis backup coverage before storing real personal or business data

### ⬜ Phase 6 — First domain agent: Finance Advisor
Start with read-heavy, low-risk:
- Watchlists, price and indicator monitoring, daily summaries via Telegram
- Explicit approval required before any side-effecting action
- No autonomous trading or order placement

After finance is stable: Shopify assistant (draft-only email replies, shipment triage) → fitness advisor (personal data, long-term habit tracking).

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

1. Create `agents/domain/{agent-name}/` directory with standard K8s manifests
2. Register the agent in `agent-api/config/agents.yaml`
3. Implement the LangGraph graph in `agent-api/src/agents/{agent_name}.py`
4. Add n8n workflow(s) for its triggers and approval routing
5. Commit — Argo CD auto-discovers and deploys

---

## Verification Checklist

- [ ] Argo CD shows agents project and ApplicationSet healthy; sync order: infra → monitoring → agents platform → domain agents
- [ ] Sealed secrets reconcile from git without plaintext credentials; pods receive runtime credentials
- [ ] PostgreSQL, Redis, n8n restart cleanly with Longhorn PVCs (no multi-attach errors)
- [ ] A scheduled n8n workflow sends a Telegram message and persists the result in PostgreSQL
- [ ] A dry-run finance workflow fetches market data, summarizes via LLM, stops at approval
- [ ] Prometheus scrapes agent metrics; Grafana shows workflow health and provider latency
- [ ] PostgreSQL backup / Longhorn snapshot restore test passes in a disposable namespace
