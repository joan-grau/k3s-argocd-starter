# Agent Platform

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

## Rollout Phases — All Complete

| Phase | What was built |
|-------|---------------|
| 1 — Governance | Argo CD `agents` project + ApplicationSets scanning `agents/platform/*` and `agents/domain/*`. Isolated from `my-apps`. |
| 2 — State foundations | Sealed Secrets, PostgreSQL 16 + pgvector, Redis 7 — all on Longhorn PVCs. |
| 3 — Orchestration | n8n connected to PostgreSQL; Telegram bot as notification and interaction channel. |
| 4 — Agent runtime | FastAPI + LangGraph service, 5-tier LLM routing, personal assistant with full Mem0 memory stack. See [agent-api/docs/memory.md](https://github.com/joan-grau/agent-api/blob/main/docs/memory.md). |
| 5 — Observability | Prometheus metrics (latency, tokens, cache, memory ops), Grafana dashboard, ResourceQuotas, Longhorn daily snapshots. |
| 6 — Finance Advisor | `src/agents/finance.py` — yfinance tools (`get_quote`, `get_technical_indicators`, `get_daily_summary`), watchlist in agent workspace, daily Telegram summary at 08:00 CET, interactive via Telegram router. Read-only. |

---

## Adding a Domain Agent

> Implementation details (Python code, LLM tier table, inherited capabilities) live in the agent-api repo:
> [`docs/adding-an-agent.md`](https://github.com/joan-grau/agent-api/blob/main/docs/adding-an-agent.md)

Infra steps:
1. Register the agent in `agents/platform/agent-api/configmap.yaml` under `agents:` — set `memory: true` for production agents
2. Add n8n workflow(s) for triggers (cron, Telegram intent, webhook, approval loops)
3. Commit — Argo CD picks up the ConfigMap change and agent-api reloads

---

## n8n Workflow Inventory

| Workflow file | Trigger | Purpose |
|--------------|---------|---------|
| `telegram-agent-router.json` | Telegram webhook | Routes Telegram messages to agent-api |
| `memory-lifecycle.json` | Daily + monthly cron | Compact and expire long-term memories |

---

## Verification Checklist

- [x] Argo CD shows agents project and ApplicationSet healthy; sync order: infra → monitoring → agents platform → domain agents
- [x] Sealed secrets reconcile from git without plaintext credentials; pods receive runtime credentials
- [x] PostgreSQL, Redis, n8n restart cleanly with Longhorn PVCs (no multi-attach errors)
- [x] A scheduled n8n workflow sends a Telegram message and persists the result in PostgreSQL
- [x] Finance workflow fetches market data, summarizes via LLM, delivers daily Telegram summary
- [x] Prometheus scrapes agent metrics; Grafana shows workflow health and provider latency
- [x] PostgreSQL backup / Longhorn snapshot restore test passes in a disposable namespace
