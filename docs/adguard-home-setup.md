# AdGuard Home DNS Server Setup

This guide explains how to set up AdGuard Home **inside your Kubernetes cluster** to handle local `.local` domain resolution.

## Overview

AdGuard Home runs as a Kubernetes Deployment and provides:
- DNS resolution for `*.local` domains → Gateway LoadBalancer
- Ad blocking and privacy protection
- DNS query logging and statistics
- Web UI for management at `https://adguard.local`

## Prerequisites

- Kubernetes cluster with this starter kit deployed
- Gateway API and Cilium configured
- Router with DHCP configuration access

## Architecture

```
Your Devices
    ↓ DNS Query: homebridge.local
AdGuard Home (192.168.0.53)
    ↓ *.local → Returns 192.168.0.35
Gateway LoadBalancer (192.168.0.35)
    ↓ HTTPRoute matches hostname
Homebridge / RSSHub / etc.
```

## Deployment

### 1. Deploy AdGuard Home

```bash
# Deploy AdGuard Home to the cluster
kubectl apply -k my-apps/adguard-home/

# Wait for DNS service to get LoadBalancer IP
kubectl get svc adguard-home-dns -n adguard-home --watch
# Wait until EXTERNAL-IP shows: 192.168.0.53
```

### 2. Verify Deployment

```bash
# Check pods are running
kubectl get pods -n adguard-home

# Check LoadBalancer IP
kubectl get svc -n adguard-home
# Expected:
# NAME                 TYPE           EXTERNAL-IP    PORT(S)
# adguard-home-dns     LoadBalancer   192.168.0.53   53/TCP,53/UDP
# adguard-home-web     ClusterIP      10.43.x.x      80/TCP
```

### 3. Initial Web UI Setup

Access AdGuard Home web interface for first-time setup:

**Before DNS is configured** (direct IP):
```
http://192.168.0.53:3000
```

**After router DNS is configured** (via Gateway):
```
https://adguard.local
```

Complete the setup wizard:
1. Create admin username and password
2. Accept default ports (pre-configured)
3. Complete setup

### 4. Configure DNS Rewrites

After setup, go to **Filters** → **DNS rewrites** and add:

| Domain | Answer |
|--------|--------|
| `*.local` | `192.168.0.35` |

**Get your Gateway IP:**
```bash
kubectl get svc gateway-internal -n gateway -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

## Configure Router DHCP

Update your router's DHCP DNS settings to point devices to AdGuard Home:

- **Primary DNS**: `192.168.0.53` (AdGuard Home in cluster)
- **Secondary DNS**: `8.8.8.8` (fallback when cluster is down)

**Common router locations:**
- **UniFi**: Settings → Networks → [Network] → DHCP → DNS Server
- **Firewalla**: Network Settings → DHCP → DNS Servers
- **pfSense**: Services → DHCP Server → DNS Servers
- **OpenWRT**: Network → Interfaces → LAN → DHCP Server → Advanced → DNS

## Testing & Verification

```bash
# Test local domain resolution
nslookup homebridge.local
# Should return: 192.168.0.35

# Test public domain resolution (should still work)
nslookup google.com

# Test directly against AdGuard
nslookup homebridge.local 192.168.0.53
```

## Adding New Local Domains

When you add a new app to the cluster:

1. Go to AdGuard **Filters** → **DNS rewrites**
2. If you already have `*.local → 192.168.0.35` wildcard, no action needed
3. Otherwise add: `myapp.local → 192.168.0.35`

## Troubleshooting

### AdGuard Home not starting
```bash
kubectl get pods -n adguard-home
kubectl logs -n adguard-home deployment/adguard-home
kubectl get pvc -n adguard-home
```

### LoadBalancer IP not assigned
```bash
# Verify IP pool includes .53
kubectl get CiliumLoadBalancerIPPool -n kube-system

# Check L2 announcement
kubectl get CiliumL2AnnouncementPolicy -n kube-system
```

### DNS not resolving on devices
```bash
# Check device got the right DNS server
# macOS/Linux:
cat /etc/resolv.conf  # Should show: nameserver 192.168.0.53

# Test DNS server directly
ping 192.168.0.53
nslookup homebridge.local 192.168.0.53
```

### Cluster down - DNS behaviour

When Kubernetes cluster is down:
- ✅ **Internet still works** — devices use secondary DNS (8.8.8.8)
- ❌ **`.local` domains fail** — expected, cluster services are also down
- No manual intervention needed — automatic DNS failover

## Security Notes

- ✅ Web UI via HTTPS at `https://adguard.local` (self-signed cert)
- ✅ DNS service (`192.168.0.53`) accessible only from local network
- ⚠️ Set a strong admin password during initial setup

## Related Documentation

- [Migration Guide](migration-guide.md) — Migrating services to Kubernetes
- [README](../readme.md) — Main cluster documentation
