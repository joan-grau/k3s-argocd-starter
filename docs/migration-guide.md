# Migration Guide: Docker Compose to Kubernetes

This guide covers migrating Homebridge and RSSHub from Docker Compose to this Kubernetes cluster.

## Prerequisites

- Kubernetes cluster running with ArgoCD
- `kubectl` configured and connected to your cluster
- Access to your Docker Compose host to retrieve data
- Router with DHCP configuration access

## DNS Setup with AdGuard Home

This setup includes AdGuard Home running **inside the Kubernetes cluster** for local domain resolution.

### 1. Deploy AdGuard Home

```bash
# Deploy AdGuard Home to the cluster
kubectl apply -k my-apps/adguard-home/

# Wait for DNS service to get LoadBalancer IP
kubectl get svc adguard-home-dns -n adguard-home --watch
# Wait until EXTERNAL-IP shows: 192.168.0.53
```

### 2. Configure Router DHCP

Update your router's DHCP DNS settings to point devices to AdGuard Home:

**Primary DNS**: `192.168.0.53` (AdGuard Home in cluster)  
**Secondary DNS**: `8.8.8.8` or `1.1.1.1` (fallback when cluster is down)

**Common Router Locations:**
- **UniFi**: Settings → Networks → [Your Network] → DHCP → DNS Server
- **Firewalla**: Network Settings → DHCP → DNS Servers
- **pfSense**: Services → DHCP Server → DNS Servers
- **OpenWRT**: Network → Interfaces → LAN → DHCP Server → Advanced → DNS

### 3. Initial AdGuard Home Setup

After DNS service is ready, access the web UI:

**Option A - Via Domain** (after DNS propagates, ~5 minutes):
```bash
https://adguard.local
```

**Option B - Direct IP** (immediate access):
```bash
http://192.168.0.53:3000
```

Complete the initial setup wizard:
1. Click "Get Started"
2. Accept default ports (53 for DNS, 3000 for web)
3. Create admin username and password
4. Complete setup

### 4. Configure DNS Rewrites

After initial setup, configure DNS rewrites for your cluster services:

1. Go to **Filters** → **DNS rewrites**
2. Add the following rewrites:

| Domain | Answer (IP) |
|--------|-------------|
| `*.local` | `192.168.0.35` |

Or add individual entries:

```
homebridge.local → 192.168.0.35
rsshub.local → 192.168.0.35
adguard.local → 192.168.0.35
```

**To find your Gateway IP:**
```bash
kubectl get svc gateway-internal -n gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

### 5. Test DNS Resolution

```bash
# Test from any device on your network
nslookup homebridge.local
nslookup rsshub.local
nslookup adguard.local

# All should return: 192.168.0.35
```

### Notes on DNS Architecture

- ✅ **AdGuard runs in cluster** - manages `*.local` domain resolution
- ✅ **Config in Git** - managed via GitOps, versioned
- ✅ **Persistent storage** - config stored in Longhorn PVC
- ⚠️ **If cluster is down** - devices fall back to secondary DNS (8.8.8.8)
  - Internet browsing still works
  - `*.local` domains won't resolve (expected - services are down anyway)

## Migration Steps

### 1. Deploy Applications (Data Migration Ready)

```bash
# Apply both applications
kubectl apply -k my-apps/homebridge/
kubectl apply -k my-apps/rsshub/

# Wait for PVCs to be bound
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/homebridge-config -n homebridge --timeout=60s
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/redis-data -n rsshub --timeout=60s
```

### 2. Migrate Homebridge Data

Homebridge starts with `replicas: 0` to allow data migration:
### 5. Test Access

From your local network:

```bash
# Test Homebridge (after DNS propagation)
curl -k https://homebridge.local

# Test RSSHub locally (optional - mainly accessed via Cloudflare)
curl -k https://rsshub.local/healthz

# Test RSSHub via Cloudflare tunnel (primary access method)
curl https://rss.pascualgrau.com/healthz
```

### 6. Update IoT Devices

Update your IoT devices to use the new Homebridge URL:
- **Old**: `http://192.168.0.25:8581`
- **New**: `https://homebridge.local`

Most smart home devices support custom server URLs. Check your device's network settings or Homebridge plugin configuration.
      claimName: homebridge-config
EOF

# Wait for pod to be ready
kubectl wait --for=condition=Ready pod/homebridge-migration -n homebridge --timeout=120s

# Copy data from Docker volume (run from your Docker host)
# Replace /path/to/your/docker/volumes with actual path
kubectl cp /path/to/your/docker/volumes/homebridge/. homebridge/homebridge-migration:/homebridge/ -c busybox

# Verify data was copied
kubectl exec -n homebridge homebridge-migration -- ls -la /homebridge

# Delete migration pod
kubectl delete pod homebridge-migration -n homebridge

# Scale up Homebridge
kubectl scale deployment homebridge --replicas=1 -n homebridge

# Monitor startup
kubectl logs -n homebridge -l app=homebridge -f
```

### 3. Update Cloudflare Tunnel for RSSHub

Update your Cloudflare tunnel configuration to point to the Kubernetes service:

```yaml
# infrastructure/networking/cloudflared/config.yaml
# Add or update:
ingress:
  - hostname: rss.pascualgrau.com
    service: http://rsshub.rsshub.svc.cluster.local:80
```

Apply the changes:
```bash
kubectl apply -k infrastructure/networking/cloudflared/
kubectl rollout restart deployment/cloudflared -n cloudflared
```

### 4. Verify Deployments

```bash
# Check all pods are running
kubectl get pods -n homebridge
kubectl get pods -n rsshub

# Check services have endpoints
kubectl get svc -n homebridge
kubectl get svc -n rsshub

# Test internal access
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- curl http://homebridge.homebridge.svc.cluster.local
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- curl http://rsshub.rsshub.svc.cluster.local/healthz
```

### 5. Test Access

From your local network:

```bash
# Test Homebridge (after DNS propagation)
curl -k https://homebridge.local

# Test RSSHub locally
curl -k https://rsshub.local/healthz

# Test RSSHub via Cloudflare tunnel
curl https://rss.pascualgrau.com/healthz
```

### 6. Update IoT Devices

Update your IoT devices to use the new Homebridge URL:
- **Old**: `http://192.168.0.25:8581`
- **New**: `https://homebridge.local`

## Rollback Plan

If something goes wrong:

### Homebridge Rollback
```bash
# Scale down Kubernetes deployment
kubectl scale deployment homebridge --replicas=0 -n homebridge

# Restart Docker Compose on your Docker host
cd /path/to/docker-compose/homebridge
docker-compose up -d
```

### RSSHub Rollback
```bash
# Delete Kubernetes deployment
kubectl delete -k my-apps/rsshub/

# Restart Docker Compose on your Docker host
cd /path/to/docker-compose/rsshub
docker-compose up -d

# Revert Cloudflare tunnel config to point to old service
```

## Post-Migration Cleanup

**Wait at least 1 week** before removing Docker Compose services to ensure everything is stable.

```bash
# Stop Docker Compose services
docker-compose down

# Optional: Remove volumes (⚠️ BACKUP FIRST!)
docker-compose down -v
```

## Monitoring

Access your monitoring dashboards:
- **Grafana**: Check the service URL in `monitoring/kube-prometheus-stack/`
- **Prometheus**: Check the service URL in `monitoring/kube-prometheus-stack/`

Both Homebridge and RSSHub pods will be automatically monitored.

## Troubleshooting

### Homebridge not accessible
```bash
# Check pod status
kubectl get pods -n homebridge
kubectl describe pod -n homebridge -l app=homebridge

# Check logs
kubectl logs -n homebridge -l app=homebridge --tail=100

# Check service endpoints
kubectl get endpoints -n homebridge
```

### RSSHub not working
```bash
# Check all components
kubectl get pods -n rsshub

# Check Redis
kubectl logs -n rsshub -l app=redis

# Check Browserless
kubectl logs -n rsshub -l app=browserless

# Check RSSHub
kubectl logs -n rsshub -l app=rsshub --tail=100
### DNS not resolving
```bash
# From a client machine, check DNS resolution
nslookup homebridge.local
nslookup rsshub.local

# Check AdGuard Home is running
kubectl get pods -n adguard-home
kubectl logs -n adguard-home -l app=adguard-home

# Check AdGuard Home has LoadBalancer IP
kubectl get svc adguard-home-dns -n adguard-home

# Verify DNS rewrites in AdGuard web UI
# Access: https://adguard.local or http://192.168.0.53:3000
# Check: Filters → DNS rewrites

# Test DNS directly
nslookup homebridge.local 192.168.0.53
```
## Notes

- **Homebridge**: Data is preserved in Longhorn PVC, replicated across nodes
- **RSSHub**: Redis data is in Longhorn PVC, other components are stateless
- **AdGuard Home**: DNS server runs in cluster, config stored in Longhorn PVC
- **Cloudflare Tunnel**: External access to RSSHub via `rss.pascualgrau.com`
- **Local Access**: All services accessible via `*.local` domains internally
- **HTTPS**: Self-signed certificates via cert-manager for local access
- **DNS Fallback**: If cluster is down, devices use secondary DNS (8.8.8.8) for internet access

## Service URLs Summary

| Service | Local URL | External URL | Purpose |
|---------|-----------|--------------|---------|
| **Homebridge** | `https://homebridge.local` | ❌ None | Smart home control |
| **RSSHub** | `https://rsshub.local` | `https://rss.pascualgrau.com` | RSS feed generator |
| **AdGuard Home** | `https://adguard.local` | ❌ None | DNS management UI |
| **Gateway IP** | `192.168.0.35` | N/A | All `*.local` domains |
| **DNS Server** | `192.168.0.53` | N/A | AdGuard Home |
kubectl get certificate -n rsshub

# Describe certificate for details
kubectl describe certificate homebridge-tls -n homebridge
kubectl describe certificate rsshub-tls -n rsshub
```

## Notes

- **Homebridge**: Data is preserved in Longhorn PVC, replicated across nodes
- **RSSHub**: Redis data is in Longhorn PVC, other components are stateless
- **Cloudflare Tunnel**: External access to RSSHub via `rss.pascualgrau.com`
- **Local Access**: Both services accessible via `*.local` domain internally
- **HTTPS**: Self-signed certificates via cert-manager for local access
