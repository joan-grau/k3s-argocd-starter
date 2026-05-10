# K3s ArgoCD Starter — Repository Context

> **Purpose of this file**: Single-source knowledge base so AI assistants and humans can understand this repo without scanning every file. Keep this file updated when architecture changes.

## What This Repo Is

A **GitOps-managed homelab Kubernetes platform** running on a single Intel NUC. It uses K3s as the Kubernetes distribution and Argo CD as the GitOps controller. All infrastructure, applications, and monitoring are declared in this repo and auto-synced to the cluster.

**Owner domain**: `pascualgrau.com` (external) / `*.lan` (internal)  
**Cluster node IP**: `192.168.0.25`  
**Gateway LoadBalancer IP**: `192.168.0.35`  
**AdGuard DNS IP**: `192.168.0.53`

---

## Technology Stack

| Layer | Technology | Version | Notes |
|-------|-----------|---------|-------|
| K8s Distribution | K3s | 1.33.3+k3s1 | Single-node, no kube-proxy (replaced by Cilium) |
| GitOps | Argo CD | Helm chart 9.0.6 | Custom CMP plugin for kustomize+helm |
| CNI / Service Mesh | Cilium | 1.18.3 | L2 announcements, Gateway API, Hubble |
| Ingress | Gateway API (Cilium) | v1 | Single gateway at 192.168.0.35 |
| DNS Tunnel | Cloudflare Tunnel (cloudflared) | 2025.1.0 | Exposes select services to internet |
| TLS | cert-manager | v1.19.1 | Self-signed for *.lan, Let's Encrypt for public |
| Storage | Longhorn | 1.10.0 | Single-replica, default StorageClass |
| Monitoring | kube-prometheus-stack | 79.1.1 | Prometheus + Grafana + Alertmanager |
| Config Management | Kustomize + Helm | — | CMP sidecar in ArgoCD repo-server |

---

## Directory Structure & Argo CD Projects

```
k3s-argocd-starter/
├── infrastructure/          ← Argo CD Project: "infrastructure" (sync-wave: -2)
│   ├── controllers/
│   │   ├── argocd/          ← Argo CD itself (Helm + Kustomize)
│   │   ├── cert-manager/    ← TLS bootstrap (sync-wave: -10, deploys FIRST)
│   │   └── sealed-secrets/  ← Bitnami Sealed Secrets controller (Helm)
│   ├── networking/
│   │   ├── cilium/          ← CNI, L2 policy, IP pool
│   │   ├── gateway/         ← GatewayClass + Gateway (*.lan listeners)
│   │   └── cloudflared/     ← DaemonSet tunnel to Cloudflare
│   └── storage/
│       ├── longhorn/        ← Block storage CSI
│       ├── csi-driver-nfs/  ← NFS CSI (optional)
│       └── csi-driver-smb/  ← SMB CSI (optional)
├── monitoring/              ← Argo CD Project: "monitoring" (sync-wave: 0)
│   └── kube-prometheus-stack/
│       ├── values.yaml      ← Prometheus, Grafana, Alertmanager config
│       └── dashboards/      ← ConfigMap-based Grafana dashboards
├── agents/                  ← Argo CD Project: "agents" (sync-wave: 2)
│   ├── platform/
│   │   ├── postgresql/      ← Shared state store (Postgres 16, Longhorn PVC)
│   │   ├── redis/           ← Shared cache + locks (Redis 7, Longhorn PVC)
│   │   ├── n8n/             ← Workflow engine (backed by PostgreSQL, n8n.lan)
│   │   └── agent-api/       ← LangGraph runtime (FastAPI, multi-tier LLM, agent-api.lan)
│   └── domain/              ← Future domain agents (finance, shopify, etc.)
├── my-apps/                 ← Argo CD Project: "applications" (sync-wave: 1)
│   ├── adguard-home/        ← Network-wide DNS ad blocker
│   ├── headlamp/            ← K8s dashboard (Helm)
│   ├── hello-world/         ← Minimal echo server (test app)
│   ├── homebridge/          ← Apple HomeKit bridge
│   ├── homepage-dashboard/  ← Homepage dashboard
│   ├── it-tools/            ← Developer tools collection
│   ├── nginx/               ← Static site
│   └── rsshub/              ← RSS feed aggregator (multi-container: app + redis + browserless)
└── docs/                    ← Supplemental documentation
```

---

## How Deployment Works (GitOps Flow)

### ApplicationSet Pattern
Four `ApplicationSet` resources auto-discover apps from directory structure:

1. **`infrastructure/infrastructure-components-appset.yaml`** — Scans `infrastructure/{networking,storage,controllers}/*`
2. **`monitoring/monitoring-components-appset.yaml`** — Scans `monitoring/*`
3. **`my-apps/myapplications-appset.yaml`** — Scans `my-apps/*`
4. **`agents/agents-appset.yaml`** — Scans `agents/platform/*` and `agents/domain/*`

Each subdirectory becomes an Argo CD `Application`. The namespace is derived from `{{path.basename}}`.

### Sync Wave Order (deployment priority)
1. **-10**: cert-manager (TLS bootstrap)
2. **-2**: Infrastructure (networking, storage, controllers, sealed-secrets)
3. **0**: Monitoring
4. **1**: User applications
5. **2**: Agent platform and domain agents

### Config Management
- **Kustomize + Helm hybrid** via ArgoCD CMP plugin (`kustomize-build-with-helm`)
- Each component has a `kustomization.yaml` that may include `helmCharts:` entries
- Helm values are in `values.yaml` files alongside their `kustomization.yaml`

---

## Networking Architecture

```
Internet → Cloudflare Tunnel (DaemonSet) → In-cluster Services (*.pascualgrau.com)
LAN      → DNS rewrite (AdGuard) → 192.168.0.35 → Cilium Gateway → HTTPRoute → Service (*.lan)
```

### Key Components
- **Cilium L2 Announcements**: Advertises LoadBalancer IPs (192.168.0.35, 192.168.0.53) to LAN
- **IP Pool**: `192.168.0.35/32` (gateway), `192.168.0.53/32` (DNS)
- **Gateway**: Single `gateway-internal` in namespace `gateway`, listens on HTTP/80 and HTTPS/443 for `*.lan`
- **HTTPRoutes**: Each app creates an HTTPRoute pointing to `gateway-internal` with hostname `{app}.lan`
- **Cloudflare Tunnel**: Routes specific public hostnames to internal services via `config.yaml`

### Public Services (via Cloudflare Tunnel)
- `rss.pascualgrau.com` → rsshub
- `argocd.pascualgrau.com` → argocd-server
- `grafana.pascualgrau.com` → prometheus-grafana
- `headlamp.pascualgrau.com` → headlamp
- `homebridge.pascualgrau.com` → homebridge

### Local Services (via Gateway *.lan)
- `argocd.lan`, `grafana.lan`, `prometheus.lan`, `longhorn.lan`, `hubble.lan`
- `hello-world.lan`, `adguard.lan`, `homebridge.lan`, `rsshub.lan`, `homepage.lan`, `it-tools.lan`
- `n8n.lan`, `agent-api.lan`

---

## Storage

- **Default StorageClass**: Longhorn (`longhorn` class)
- **Replica count**: 1 (single-node, no redundancy)
- **Reclaim policy**: Delete
- **Data path**: `/var/lib/longhorn` on host
- **Access mode**: ReadWriteOnce (all PVCs)
- **Deployment strategy**: `Recreate` for all stateful apps (avoids multi-attach errors)

---

## Monitoring

- **Prometheus**: 7-day retention, 30s scrape interval, 10Gi storage
- **Grafana**: Admin password `admin`, dashboards auto-loaded from ConfigMaps with label `grafana_dashboard`
- **Alertmanager**: 512Mi storage
- **Node Exporter**: Enabled for host metrics
- **kube-state-metrics**: Enabled for K8s object metrics

---

## Patterns & Conventions

### Adding a New App
1. Create directory `my-apps/{app-name}/`
2. Add `kustomization.yaml` listing all resources
3. Add `namespace.yaml` (namespace = directory name)
4. Add `deployment.yaml`, `service.yaml`
5. Add `http-route.yaml` → parentRef `gateway-internal` in namespace `gateway`, hostname `{app}.lan`
6. (Optional) Add `pvc.yaml` with `storageClassName: longhorn`
7. Commit and push — Argo CD auto-discovers and deploys

### Stateless App Template
- Single Deployment (replicas: 1)
- Service (ClusterIP)
- HTTPRoute
- Security: `runAsNonRoot: true`, `readOnlyRootFilesystem: true`

### Stateful App Template
- Deployment with `strategy: Recreate`
- PVC(s) with `storageClassName: longhorn`, `ReadWriteOnce`
- Liveness/readiness probes
- Resource requests and limits defined

### Multi-Container App (e.g., RSSHub)
- All deployments in same namespace
- Inter-service communication via DNS (`redis:6379`, `browserless:3000`)
- Each deployment has its own Service
- Single HTTPRoute for the main app

### Helm-based App (e.g., Headlamp)
- `kustomization.yaml` with `helmCharts:` section
- `values.yaml` for Helm overrides
- Additional raw resources alongside Helm chart

### Resource Limits Convention
- All containers have `requests` and `limits` defined
- Typical small app: 50-100m CPU, 64-256Mi memory
- Storage-intensive: up to 500m CPU, 1Gi memory

---

## Security Model

- **Pod Security**: Non-root users, read-only filesystems, no privilege escalation
- **TLS**: Self-signed for LAN (*.lan via cert-manager), Let's Encrypt for public (via Cloudflare DNS01)
- **Secrets**: Created manually outside GitOps (Cloudflare API token, app secrets)
- **Sealed Secrets**: Bitnami Sealed Secrets for GitOps-safe secret management
- **RBAC**: Four Argo CD AppProjects with separate permissions (infrastructure, monitoring, applications, agents)
- **Network**: Cilium policies, L2 isolation per namespace

---

## Secrets (NOT in repo, created manually)

| Secret | Namespace | Purpose |
|--------|-----------|---------|
| `cloudflare-api-token` | cert-manager | DNS01 challenge for Let's Encrypt |
| Cloudflare tunnel credentials | cloudflared | Tunnel authentication |
| `rsshub-secrets` | rsshub | Instagram cookies |
| ArgoCD admin password | argocd | Auto-generated by Helm |
| `postgresql-credentials` | postgresql | PostgreSQL password for agents DB |
| `redis-credentials` | redis | Redis password |
| `n8n-secrets` | n8n | DB password + encryption key |
| `agent-api-secrets` | agent-api | DB, Redis, OpenAI, Anthropic API keys |

---

## Agent Platform

The agents layer (`agents/`) is a multi-tier AI agent runtime:

- **Argo CD project**: `agents` (sync-wave 2, deploys after monitoring)
- **Secret management**: Sealed Secrets controller under `infrastructure/controllers/sealed-secrets/`
- **State stores**: PostgreSQL 16 (schemas per agent) + Redis 7 (key-prefix isolation)
- **Workflow engine**: n8n (backed by PostgreSQL, Telegram/webhook triggers)
- **Agent runtime**: FastAPI + LangGraph in `joan-grau/agent-api` (separate repo)
  - Multi-tier model registry: fast (GPT-4o-mini), standard (GPT-4o), reasoning (Claude Sonnet)
  - Each LangGraph node picks its own model tier based on task complexity
  - Agent definitions loaded from ConfigMap (`agents-config`)
- **Channel flow**: Telegram → n8n webhook → `POST /agents/{id}/invoke` → LangGraph → n8n → Telegram reply

### Future domain agents
- Finance advisor (read-heavy, approval-gated)
- Shopify assistant (draft emails, shipment triage)
- Fitness advisor (habit tracking, personal data)

---

## Quick Reference Commands

```bash
# Check cluster
kubectl get nodes
kubectl get pods -A

# ArgoCD CLI
argocd app list
argocd app sync <app-name>

# Storage
kubectl get pvc -A
kubectl get sc

# Networking
kubectl get gateway -A
kubectl get httproute -A
kubectl get ciliumloadbalancerippool

# Logs
kubectl logs -n <namespace> deployment/<name>
```

---

## File Naming Conventions

| File | Purpose |
|------|---------|
| `kustomization.yaml` | Entry point for each component (lists resources, helmCharts) |
| `values.yaml` | Helm chart overrides |
| `namespace.yaml` / `ns.yaml` | Namespace definition |
| `http-route.yaml` / `httproute.yaml` | Gateway API ingress rule |
| `deployment.yaml` | Workload definition |
| `service.yaml` | ClusterIP service |
| `pvc.yaml` | Persistent volume claim |
| `certificate.yaml` | cert-manager Certificate resource |

---

*Last updated: 2025-05-10*
