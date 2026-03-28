# Quick Start Guide

## What Was Added

### New Applications

1. **Homebridge** (`my-apps/homebridge/`)
   - Smart home bridge for HomeKit
   - Access: `https://homebridge.local`
   - Storage: 2Gi Longhorn PVC
   - Initial deployment: `replicas: 0` (for data migration)

2. **RSSHub** (`my-apps/rsshub/`)
   - RSS feed generator from social media
   - Local access: `https://rsshub.local`
   - External access: `https://rss.pascualgrau.com` (Cloudflare Tunnel)
   - Components:
     - RSSHub (main app)
     - Redis (cache with 1Gi PVC)
     - Browserless (headless Chrome)

3. **AdGuard Home** (`my-apps/adguard-home/`)
   - DNS server for `*.local` domain resolution
   - DNS service: `192.168.0.53` (UDP/TCP port 53)
   - Web UI: `https://adguard.local` or `http://192.168.0.53:3000`
   - Storage: 1Gi config + 2Gi work data

## Quick Deployment

### 1. Deploy AdGuard Home (First!)

```bash
# Deploy DNS server
kubectl apply -k my-apps/adguard-home/

# Wait for LoadBalancer IP
kubectl get svc adguard-home-dns -n adguard-home --watch
# Wait for: EXTERNAL-IP: 192.168.0.53

# Configure router DHCP DNS:
# Primary DNS: 192.168.0.53
# Secondary DNS: 8.8.8.8

# Access web UI and complete setup
open http://192.168.0.53:3000

# Configure DNS rewrites:
# *.local → 192.168.0.35 (your Gateway IP)
```

### 2. Deploy Homebridge

```bash
# Deploy with replicas=0 for data migration
kubectl apply -k my-apps/homebridge/

# Migrate data (see migration-guide.md for details)
# ... copy data from Docker volumes ...

# Scale up after migration
kubectl scale deployment homebridge --replicas=1 -n homebridge

# Verify
kubectl logs -n homebridge -l app=homebridge -f
```

### 3. Deploy RSSHub

```bash
# Update secret with your Instagram cookie
vim my-apps/rsshub/secret.yaml

# Deploy
kubectl apply -k my-apps/rsshub/

# Verify
kubectl get pods -n rsshub
kubectl logs -n rsshub -l app=rsshub

# Test
curl https://rsshub.local/healthz
curl https://rss.pascualgrau.com/healthz
```

## Service URLs

| Service | Local URL | External URL | DNS Required |
|---------|-----------|--------------|--------------|
| **AdGuard Home** | `https://adguard.local` | ❌ None | Self (192.168.0.53) |
| **Homebridge** | `https://homebridge.local` | ❌ None | ✅ AdGuard |
| **RSSHub** | `https://rsshub.local` | `https://rss.pascualgrau.com` | ✅ AdGuard (local only) |

## IP Addresses

- **Gateway**: `192.168.0.35` (all `*.local` domains)
- **AdGuard DNS**: `192.168.0.53` (DNS server)

## Common Commands

```bash
# Check all services
kubectl get pods -n homebridge
kubectl get pods -n rsshub
kubectl get pods -n adguard-home

# Check DNS
kubectl get svc adguard-home-dns -n adguard-home
nslookup homebridge.local
nslookup rsshub.local

# Check Gateway IP
kubectl get svc gateway-internal -n gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Logs
kubectl logs -n homebridge -l app=homebridge -f
kubectl logs -n rsshub -l app=rsshub -f
kubectl logs -n adguard-home -l app=adguard-home -f

# Restart services
kubectl rollout restart deployment/homebridge -n homebridge
kubectl rollout restart deployment/rsshub -n rsshub
kubectl rollout restart deployment/adguard-home -n adguard-home
```

## Troubleshooting

### DNS Not Working

```bash
# 1. Check AdGuard Home is running
kubectl get pods -n adguard-home

# 2. Check DNS service has IP
kubectl get svc adguard-home-dns -n adguard-home

# 3. Test DNS directly
nslookup homebridge.local 192.168.0.53

# 4. Check router DHCP configuration
# Ensure devices are getting 192.168.0.53 as DNS

# 5. Check AdGuard web UI
# Access: http://192.168.0.53:3000
# Verify: Filters → DNS rewrites → *.local → 192.168.0.35
```

### Can't Access Services

```bash
# 1. Check pods are running
kubectl get pods -n homebridge -n rsshub

# 2. Check Gateway IP
kubectl get svc gateway-internal -n gateway

# 3. Check certificates
kubectl get certificate -n homebridge -n rsshub

# 4. Test internal connectivity
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- curl http://homebridge.homebridge.svc.cluster.local
```

### Homebridge Data Missing

```bash
# Check PVC is bound
kubectl get pvc -n homebridge

# Check volume contents
kubectl exec -n homebridge deployment/homebridge -- ls -la /homebridge

# If empty, re-run migration (see migration-guide.md)
```

## Architecture Overview

```
Internet
  ↓
Cloudflare Tunnel (rss.pascualgrau.com)
  ↓
RSSHub (in cluster)

Local Network
  ↓
Devices get DNS: 192.168.0.53 (AdGuard in cluster)
  ↓
Query: homebridge.local
  ↓
AdGuard returns: 192.168.0.35 (Gateway)
  ↓
Gateway routes to: Homebridge/RSSHub pods
```

## Next Steps

1. ✅ Deploy AdGuard Home
2. ✅ Configure router DHCP DNS
3. ✅ Complete AdGuard initial setup
4. ✅ Configure DNS rewrites
5. ✅ Deploy Homebridge (with data migration)
6. ✅ Deploy RSSHub
7. ✅ Update IoT devices to use `homebridge.local`
8. ✅ Test all services
9. ⏳ Monitor for 1 week
10. 🗑️ Remove old Docker Compose services

For detailed step-by-step instructions, see [`docs/migration-guide.md`](docs/migration-guide.md).
