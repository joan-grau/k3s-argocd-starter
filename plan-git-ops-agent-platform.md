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