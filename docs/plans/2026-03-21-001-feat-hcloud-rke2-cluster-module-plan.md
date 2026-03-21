---
title: "feat: Build Terraform Hetzner Cloud RKE2 Cluster Module"
type: feat
status: active
date: 2026-03-21
origin: docs/brainstorms/2026-03-21-terraform-hcloud-rke2-cluster-requirements.md
deepened: 2026-03-21
---

# feat: Build Terraform Hetzner Cloud RKE2 Cluster Module

## Enhancement Summary

**Deepened on:** 2026-03-21
**Sections enhanced:** 6 (Cilium, Autoscaler, Security, Firewall, State, Risk)
**Research agents used:** best-practices-researcher × 2, security-sentinel, framework-docs-researcher, repo-research-analyst, performance-oracle

### Critical Corrections (Fix Before Writing Any Code)

1. **`HCLOUD_CLOUD_INIT` is legacy/deprecated** — The autoscaler must use `HCLOUD_CLUSTER_CONFIG` (base64-encoded JSON object) for multi-pool support. The plan's Phase 5 and autoscaler.tf references to `HCLOUD_CLOUD_INIT` must all be updated.
2. **`tunnel: vxlan` is deprecated** in Cilium 1.14+ — Replace with `routingMode: tunnel` + `tunnelProtocol: vxlan` in all Helm set blocks.
3. **Cilium `operator.replicas: 1` is a single point of failure** — Change to `2` for any 3-node production cluster. IPAM stalls if the sole operator goes down.
4. **Cilium chart version `~> 1.17` is 3 minor versions behind** — Target `1.19.1` for a module being built in March 2026.
5. **Autoscaler `cloudInit` inside `nodeConfigs` must be a raw string** — Not separately base64-encoded. The entire `HCLOUD_CLUSTER_CONFIG` JSON object is what gets base64-encoded.

### Key Improvements Added

- Complete `HCLOUD_CLUSTER_CONFIG` JSON format with multi-pool example
- Explicit MTU 1450 for Hetzner VXLAN (prevents pod network issues on multi-NIC nodes)
- Security: Metadata API egress block via CiliumNetworkPolicy post-bootstrap
- Security: Split `tailscale_auth_key` into operator + node keys (separate trust domains)
- Security: `kube_api_allowed_cidrs` variable for 6443 access restriction
- Security: `trusted_ssh_cidrs` variable for SSH restriction (default: closed)
- Autoscaler image `v1.32.7`, chart `9.46.6` from `kubernetes.github.io/autoscaler`
- Longhorn `timeout = 600`, monitoring `timeout = 600`
- `longhorn_default_replicas = min(worker_count, 3)` dynamic computation

### New Risk Considerations

- kubeconfig + rke2_token in Terraform state in plaintext — state backend must be encrypted (remote state only)
- Hetzner metadata API at `169.254.169.254` is accessible to all pods without a blocking NetworkPolicy
- `rke2_token` should not be in module outputs by default (use `expose_rke2_token` opt-in variable)
- Separate `hcloud_token` surface per component even if callers use same value today

---

## Overview

Build an org-internal Terraform module (`terraform-hcloud-rke2-cluster`) that provisions fully functional RKE2 Kubernetes clusters on Hetzner Cloud in a single `terraform apply`. The module mirrors the conventions of the production cluster `rke2-primary`, supports optional add-ons via `enable_*` variables, and provides a repeatable, version-controlled foundation for deploying new clusters across Hetzner regions.

(see origin: `docs/brainstorms/2026-03-21-terraform-hcloud-rke2-cluster-requirements.md`)

---

## Problem Statement

The sarverenterprises/heysarver org currently provisions Hetzner Cloud RKE2 clusters via manual Terraform workspaces in `heysarver/terraform-control`. The production `rke2-primary` cluster required hand-crafted resources spread across multiple files with no reusable abstraction. Provisioning a second cluster of equivalent quality would require duplicating and adapting hundreds of lines of HCL. This module encapsulates all proven patterns into a composable, well-tested module.

---

## Proposed Solution

Compose a root Terraform module backed by three submodules — `modules/networking`, `modules/node-pool`, and `modules/addons` — that together provision:

1. A 3-node HA RKE2 control plane with embedded etcd
2. One or more independently configurable worker node pools (fixed or autoscaled)
3. Required Hetzner Cloud infrastructure (private network, LB, optional firewall)
4. Required Kubernetes add-ons (Hetzner CCM + CSI, Cilium CNI)
5. Optional add-ons (external-dns, cert-manager, ingress, Longhorn, Flux CD, monitoring, Tailscale)

The module is idempotent, sensitive-variable-safe, and targets `terraform >= 1.5`. File layout follows the conventions discovered in the existing `heysarver/terraform-hcloud-rke2` sibling module.

---

## Technical Approach

### Architecture

```
terraform-hcloud-rke2-cluster/
├── versions.tf              # terraform{} block, required_providers
├── provider.tf              # provider "hcloud" {} stub (caller configures)
├── main.tf                  # Root module — calls submodules, wires together
├── variables.tf             # All input variables (with descriptions + sensitive flags)
├── outputs.tf               # kubeconfig (sensitive), cluster endpoints, network IDs
├── locals.tf                # Computed locals (cloud-init templates, name prefixes)
│
├── modules/
│   ├── networking/          # Network, subnet, firewall, placement group, LB
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── firewalls.tf     # Separated for clarity (matches production pattern)
│   │
│   ├── node-pool/           # Reusable compute pool (used for both CP and workers)
│   │   ├── main.tf          # hcloud_server resources, volume attachments
│   │   ├── variables.tf     # server_type, count, location, labels, cloud-init
│   │   ├── outputs.tf       # server IDs, IPs (private + public), join token
│   │   └── templates/
│   │       ├── cp-init.yaml.tpl       # Control-plane cloud-init (RKE2 server mode)
│   │       ├── worker-init.yaml.tpl   # Worker cloud-init (RKE2 agent mode)
│   │       └── tailscale-init.sh.tpl  # Node-level Tailscale installer snippet
│   │
│   └── addons/              # All Helm-based add-ons
│       ├── main.tf          # Orchestrates add-on deployment order
│       ├── variables.tf     # enable_* flags + per-addon config vars
│       ├── outputs.tf
│       ├── ccm.tf           # Hetzner Cloud Controller Manager
│       ├── csi.tf           # Hetzner CSI driver
│       ├── cilium.tf        # Cilium CNI (Helm override of RKE2's bundled deploy)
│       ├── external_dns.tf  # Two deployments: proxied + non-proxied Cloudflare
│       ├── cert_manager.tf  # cert-manager + ClusterIssuer (DNS-01 / Cloudflare)
│       ├── ingress.tf       # Traefik (+ Gateway API CRDs) or NGINX
│       ├── longhorn.tf      # Longhorn + StorageClasses + optional NFS server
│       ├── autoscaler.tf    # Cluster Autoscaler (Hetzner Cloud provider)
│       ├── flux.tf          # Flux CD bootstrap (fluxcd/flux provider)
│       ├── monitoring.tf    # kube-prometheus-stack
│       └── tailscale.tf     # Tailscale operator
│
└── examples/
    ├── minimal/             # CCM + CSI only — bare cluster
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    └── full/                # All add-ons enabled — mirrors rke2-primary
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

### Key Technical Decisions

#### RKE2 Bootstrap via cloud-init

RKE2 is bootstrapped via cloud-init (`user_data`) on each node. Control plane nodes run as `rke2 server`, workers as `rke2 agent`. The bootstrap sequence:

1. **First control plane node**: installs RKE2, writes `/etc/rancher/rke2/config.yaml` with `cluster-init: true`, starts `rke2-server.service`, waits for API server to be ready.
2. **Remaining control plane nodes**: install RKE2, write config with `server: <first-CP-LB-or-IP>`, `token: <cluster-token>`, start `rke2-server.service`.
3. **Worker nodes**: install RKE2 agent, write config with `server: <API-LB-IP>:9345`, `token: <cluster-token>`, start `rke2-agent.service`.

The cluster token is generated by Terraform (`random_password` resource) and injected via `templatefile()` into cloud-init. The first CP's private IP is known from `hcloud_server.control_plane[0]` and wired into subsequent nodes' configs.

**Critical RKE2 config flags** (in `config.yaml`):
```yaml
# Required for Hetzner CCM
cloud-provider-name: external

# Disable default Canal CNI so Cilium can be deployed
cni: none

# TLS SANs for API server — include LB IP + private IPs
tls-san:
  - <control_plane_lb_ip>
  - <private_ips...>
```

#### Cilium CNI Configuration

Cilium is NOT deployed via RKE2's native `cni: cilium`. Instead, `cni: none` disables Canal, and Cilium is installed via Helm **after** the cluster is up. This gives us full control over Cilium values.

**Critical constraint**: `kubeProxyReplacement` must be `false` (or omitted). Full kube-proxy replacement breaks Hetzner CCM's LoadBalancer service reconciliation. This was confirmed in production research.

```hcl
# modules/addons/cilium.tf
resource "helm_release" "cilium" {
  count      = var.enable_cilium ? 1 : 0  # Always true unless caller explicitly disables
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  namespace  = "kube-system"
  version    = var.cilium_chart_version  # default: "~> 1.17"

  set { name = "ipam.mode",              value = "cluster-pool" }
  set { name = "ipam.operator.clusterPoolIPv4PodCIDRList", value = "10.42.0.0/16" }
  set { name = "kubeProxyReplacement",   value = "false" }
  set { name = "tunnel",                 value = "vxlan" }
  set { name = "hubble.relay.enabled",   value = "true" }
  set { name = "hubble.ui.enabled",      value = "true" }
  set { name = "operator.replicas",      value = "1" }  # reduce for small clusters

  depends_on = [var.cluster_ready_trigger]
}
```

### Research Insights: Cilium CNI

**Critical Corrections:**

- **`tunnel: vxlan` is deprecated in Cilium 1.14+** — Replace with `routingMode: tunnel` + `tunnelProtocol: vxlan`. The old key still works as an alias in 1.17 but will be removed. Use current field names.
- **`operator.replicas: 1` is a SPOF** — With a 3-node HA control plane, a single Cilium operator replica means one node failure takes down IPAM entirely (new pods on new nodes can't get IPs). Change to `2`; leader election prevents split-brain.
- **Chart version: target `1.19.1`** not `~> 1.17` — As of March 2026, the current stable Cilium branch is 1.19.x (v1.19.1). Pinning to 1.17 means starting three minor versions behind. Use `~> 1.19.0`.

**MTU Setting:**

Hetzner physical MTU is 1500. VXLAN adds 50 bytes of overhead → pod MTU must be **1450**. While Cilium auto-detects MTU from the host NIC, auto-detection can silently pick the wrong interface in multi-NIC environments (known issue: cilium/cilium#14829). Set explicitly:

```hcl
set { name = "MTU", value = "1450" }
```

**Corrected Helm values block:**

```hcl
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  namespace  = "kube-system"
  version    = var.cilium_chart_version  # default: "~> 1.19.0" (NOT ~> 1.17)

  # Routing — use current field names (not deprecated `tunnel`)
  set { name = "routingMode",          value = "tunnel" }
  set { name = "tunnelProtocol",       value = "vxlan" }

  # Explicit MTU: 1500 (Hetzner NIC) - 50 (VXLAN overhead) = 1450
  set { name = "MTU",                  value = "1450" }

  # IPAM: cluster-pool is correct when using cni: none (Cilium owns all PodCIDRs)
  # Must NOT overlap Hetzner private network range — 10.42.0.0/16 is safe
  set { name = "ipam.mode",            value = "cluster-pool" }
  set { name = "ipam.operator.clusterPoolIPv4PodCIDRList", value = "10.42.0.0/16" }
  set { name = "ipam.operator.clusterPoolIPv4MaskSize",    value = "24" }

  # kubeProxyReplacement: false is REQUIRED for Hetzner CCM compatibility.
  # true causes CCM LoadBalancer reconciliation failures + bootstrap race (rancher/rke2#4862).
  # Do NOT set `disable-kube-proxy: true` in RKE2 config when this is false.
  set { name = "kubeProxyReplacement", value = "false" }

  # Operator HA: 2 replicas for 3-node cluster
  # Leader election handles active/standby; prevents IPAM stalls on node failure
  set { name = "operator.replicas",    value = "2" }

  # Hubble observability — production recommended settings
  set { name = "hubble.enabled",           value = "true" }
  set { name = "hubble.relay.enabled",     value = "true" }
  set { name = "hubble.relay.replicas",    value = "2" }  # HA relay
  set { name = "hubble.ui.enabled",        value = "true" }

  depends_on = [var.cluster_ready_trigger]
}
```

**IPv6 Dual-Stack (when enabled):**

Add to RKE2 config.yaml:
```yaml
cluster-cidr: "10.42.0.0/16,2001:cafe:42::/56"
service-cidr: "10.43.0.0/16,2001:cafe:43::/112"
```

Additional Cilium values:
```hcl
set { name = "ipv6.enabled",                                 value = "true" }
set { name = "ipam.operator.clusterPoolIPv6PodCIDRList",     value = "2001:cafe:42::/56" }
set { name = "ipam.operator.clusterPoolIPv6MaskSize",        value = "64" }
```

**Note:** `disable-kube-proxy: true` in RKE2 config must NOT be set when `kubeProxyReplacement: false`. Only needed if/when upgrading to full kube-proxy replacement in the future.

**References:**
- [Cilium Routing Docs](https://docs.cilium.io/en/stable/network/concepts/routing/)
- [Cilium IPAM cluster-pool](https://docs.cilium.io/en/stable/network/concepts/ipam/cluster-pool/)
- [kube-proxy free doc](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)
- [rancher/rke2#4862](https://github.com/rancher/rke2/issues/4862) — kubeProxyReplacement + RKE2 bootstrap race

#### Helm Provider Dependency Ordering

The `helm` and `kubernetes` providers are configured with the provisioned cluster's kubeconfig. Attribute-level dependency (passing kubeconfig values into provider config) creates implicit ordering in the Terraform graph. **Explicit `depends_on` is also required** for resources that can't use attribute-level dependency.

Correct ordering:
```
hcloud infrastructure → RKE2 nodes → Cilium → CCM → CSI → cert-manager → external-dns → ingress → Longhorn → Autoscaler → monitoring → Tailscale → Flux (last)
```

The root `main.tf` passes the cluster kubeconfig to the `addons` module, which uses it to configure the helm/kubernetes provider. The addons module internally orders with `depends_on` chains.

#### Cluster Autoscaler Design

The Hetzner Cluster Autoscaler requires a cloud-init that can join new nodes to the cluster. This cloud-init is **identical to the worker node cloud-init** — it must contain the server URL and join token. Terraform computes it via `templatefile()` and passes it as a base64-encoded env var to the autoscaler deployment.

```hcl
locals {
  autoscaler_cloud_init_b64 = base64encode(
    templatefile("${path.module}/../../modules/node-pool/templates/worker-init.yaml.tpl", {
      rke2_version = var.rke2_version
      server_url   = "https://${var.control_plane_lb_ip}:9345"
      token        = var.rke2_cluster_token
      # tailscale fields if node-level tailscale enabled
    })
  )
}
```

Node groups are declared in the autoscaler `--nodes` flags:
```
--nodes=<min>:<max>:<server_type>:<location>:<pool_name>
```
e.g. `--nodes=1:10:cpx41:ash:workers-general`

### Research Insights: Cluster Autoscaler

**Critical Correction — `HCLOUD_CLOUD_INIT` is legacy; use `HCLOUD_CLUSTER_CONFIG`:**

The plan incorrectly references `HCLOUD_CLOUD_INIT` in Phase 5. This is the legacy single-pool path. The current multi-pool format requires `HCLOUD_CLUSTER_CONFIG`. The autoscaler code checks them in order:

| Variable | Format | Status |
|---|---|---|
| `HCLOUD_CLUSTER_CONFIG` | Base64-encoded JSON object with per-pool `nodeConfigs` | **Current / required for multi-pool** |
| `HCLOUD_CLUSTER_CONFIG_FILE` | Path to plain JSON file (same structure, NOT base64) | Alternative |
| `HCLOUD_CLOUD_INIT` | Base64-encoded raw cloud-init script, single global | Legacy / deprecated |

When `HCLOUD_CLUSTER_CONFIG` is set, each `--nodes` pool name **must** have a matching key in `nodeConfigs` or the autoscaler fatal-errors at startup.

**Complete `HCLOUD_CLUSTER_CONFIG` JSON format:**

```hcl
locals {
  # For each autoscaled pool, build a nodeConfig entry
  autoscaler_cluster_config = jsonencode({
    imagesForArch = {
      amd64 = "ubuntu-24.04"
      arm64 = "ubuntu-24.04"
    }
    defaultSubnetIPRange = var.cluster_subnet_cidr

    nodeConfigs = {
      for pool in var.node_pools : pool.name => {
        # cloudInit is a RAW STRING — NOT base64-encoded separately
        # The entire JSON object is what gets base64-encoded
        cloudInit = templatefile("${path.module}/../node-pool/templates/worker-init.yaml.tpl", {
          rke2_version = var.rke2_version
          server_url   = "https://${var.control_plane_lb_ip}:9345"
          token        = var.rke2_cluster_token
          enable_tailscale = var.enable_tailscale_nodes
          tailscale_auth_key = var.tailscale_node_auth_key
        })
        labels = merge(pool.labels, {
          "node.kubernetes.io/pool" = pool.name
        })
        taints = [
          for t in pool.taints : {
            key    = t.key
            value  = t.value
            effect = t.effect
          }
        ]
      } if pool.scaling_mode == "autoscaled"
    }
  })
}

# The env var value is the base64-encoded JSON
# value = base64encode(local.autoscaler_cluster_config)
```

**Correct env var names for the autoscaler deployment:**

```hcl
env {
  name  = "HCLOUD_TOKEN"
  value_from {
    secret_key_ref {
      name = kubernetes_secret.autoscaler.metadata[0].name
      key  = "token"
    }
  }
}
env {
  name = "HCLOUD_CLUSTER_CONFIG"  # NOT HCLOUD_CLOUD_INIT
  value_from {
    secret_key_ref {
      name = kubernetes_secret.autoscaler.metadata[0].name
      key  = "clusterConfig"  # base64-encoded JSON stored in K8s Secret
    }
  }
}
env {
  name  = "HCLOUD_NETWORK"
  value = var.private_network_name
}
```

**Helm chart and image:**

```hcl
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.46.6"  # matches appVersion 1.32.0
  namespace  = "kube-system"

  set { name = "cloudProvider",  value = "hetzner" }
  set { name = "image.tag",      value = "v1.32.7" }  # match cluster K8s version

  # Each autoscaled pool gets one --nodes flag
  # Format: min:max:machine-type:region:pool-name (5 tokens, colon-separated)
  # Pool name MUST match key in HCLOUD_CLUSTER_CONFIG nodeConfigs
  dynamic "set" {
    for_each = [for p in var.node_pools : p if p.scaling_mode == "autoscaled"]
    content {
      name  = "extraArgs.nodes[${set.key}]"
      value = "${set.value.min_nodes}:${set.value.max_nodes}:${set.value.server_type}:${set.value.location}:${set.value.name}"
    }
  }
}
```

**`--nodes` flag format confirmed:**
```
--nodes=<min>:<max>:<machine-type>:<region>:<pool-name>
```
Machine type and region are case-insensitive (lowercased internally). Pool name is case-sensitive and must match `nodeConfigs` key exactly.

**Image tag policy:** The autoscaler image must match the cluster's Kubernetes minor version. For RKE2 v1.32.x, use `v1.32.7` (latest patch as of Q1 2026). Do not use `:latest`.

**Security note:** Store both `HCLOUD_TOKEN` and `HCLOUD_CLUSTER_CONFIG` in a Kubernetes Secret (not plain env vars on the Deployment). The cluster config contains the RKE2 join token — readable by anyone who can `kubectl get deploy -o yaml` if stored as plain env.

**References:**
- [Hetzner CA provider source](https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler/cloudprovider/hetzner)
- [autoscaler chart on ArtifactHub](https://artifacthub.io/packages/helm/cluster-autoscaler/cluster-autoscaler)

#### Longhorn Data Volume Attachment

When `longhorn_data_volume_size > 0` for a worker pool, the module creates `hcloud_volume` resources and attaches them to each node before deploying Longhorn. The Longhorn Helm chart is then configured with `defaultDataPath: /mnt/longhorn` (the mount point of the attached volume).

```hcl
# modules/node-pool/main.tf
resource "hcloud_volume" "longhorn_data" {
  count    = var.longhorn_volume_size > 0 ? var.node_count : 0
  name     = "${var.pool_name}-longhorn-${count.index}"
  size     = var.longhorn_volume_size
  location = var.location
}

resource "hcloud_volume_attachment" "longhorn_data" {
  count     = var.longhorn_volume_size > 0 ? var.node_count : 0
  volume_id = hcloud_volume.longhorn_data[count.index].id
  server_id = hcloud_server.nodes[count.index].id
  automount = true
}
```

The `automount = true` on `hcloud_volume_attachment` mounts the volume under `/dev/disk/by-id/scsi-*`. The cloud-init formats it (ext4) and mounts it at `/mnt/longhorn` in `fstab`. The addons module `depends_on` the node-pool outputs to ensure volumes are attached before Longhorn is Helmed.

### Research Insights: Longhorn

**Replica count must be dynamic:**

Longhorn's `defaultReplicasCount` setting must not exceed the number of available worker nodes — otherwise volumes are provisioned in a "Degraded" state and can never become healthy. Compute this dynamically:

```hcl
locals {
  # Sum of all fixed worker pool counts (autoscaled pools use min_nodes as floor)
  total_worker_nodes = sum([
    for pool in var.node_pools :
    pool.scaling_mode == "autoscaled" ? pool.min_nodes : pool.node_count
    if pool.role == "worker"
  ])
  # Longhorn replicas: max HA benefit is 3; never exceed node count
  longhorn_default_replicas = min(local.total_worker_nodes, 3)
}
```

Pass this to the Longhorn Helm release:
```hcl
set { name = "defaultSettings.defaultReplicaCount", value = tostring(local.longhorn_default_replicas) }
```

**Helm release timeout:**

Longhorn takes longer than the default 5-minute Helm timeout to provision all DaemonSet pods and initialize storage. Set `timeout = 600` (10 minutes):

```hcl
resource "helm_release" "longhorn" {
  # ...
  timeout = 600
  # ...
}
```

**StorageClass definitions matching rke2-primary conventions:**

```hcl
resource "kubernetes_storage_class" "longhorn_default" {
  metadata {
    name = "longhorn"
    annotations = { "storageclass.kubernetes.io/is-default-class" = "true" }
  }
  storage_provisioner    = "driver.longhorn.io"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true
  parameters = {
    numberOfReplicas    = tostring(local.longhorn_default_replicas)
    staleReplicaTimeout = "2880"
    fromBackup          = ""
  }
}

resource "kubernetes_storage_class" "longhorn_ha" {
  metadata { name = "longhorn-ha" }
  storage_provisioner    = "driver.longhorn.io"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true
  parameters = {
    numberOfReplicas    = "3"  # always 3 replicas for HA class
    staleReplicaTimeout = "2880"
  }
}

resource "kubernetes_storage_class" "longhorn_rwx" {
  metadata { name = "longhorn-rwx" }
  storage_provisioner    = "driver.longhorn.io"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true
  parameters = {
    numberOfReplicas    = tostring(local.longhorn_default_replicas)
    accessMode          = "ReadWriteMany"
    staleReplicaTimeout = "2880"
  }
}
```

**Hetzner SCSI volume path pattern:**

Hetzner volumes attach as SCSI devices. The `/dev/disk/by-id/` path follows the pattern `scsi-0HC_Volume_<volume-id>`. Use the volume ID (from `hcloud_volume.id`) to construct the cloud-init format command:

```yaml
# In worker-init.yaml.tpl (conditional on longhorn_volume_size > 0)
%{ if longhorn_volume_size > 0 ~}
runcmd:
  - |
    # Wait for Hetzner volume to appear
    timeout 60 bash -c 'until ls /dev/disk/by-id/scsi-0HC_Volume_* 2>/dev/null; do sleep 2; done'
    DISK=$(ls /dev/disk/by-id/scsi-0HC_Volume_* | head -1)
    if ! blkid "$DISK" 2>/dev/null | grep -q ext4; then
      mkfs.ext4 "$DISK"
    fi
    mkdir -p /mnt/longhorn
    echo "$DISK /mnt/longhorn ext4 defaults,nofail 0 2" >> /etc/fstab
    mount /mnt/longhorn
%{ endif ~}
```

#### Two External-DNS Deployments

Matching `rke2-primary` conventions (see origin: `CLAUDE_rke2-primary.md`):

```hcl
# Deployment 1: DNS-only (Cloudflare orange cloud OFF)
resource "helm_release" "external_dns_dns_only" {
  name  = "external-dns-cloudflare"
  # ... cloudflare provider, no proxy
  set { name = "cloudflare.proxied", value = "false" }
  set { name = "txtOwnerId",         value = "${var.cluster_name}-dns" }
  set { name = "domainFilters[0]",   value = var.cloudflare_zone }
  # annotationFilter: external-dns.alpha.kubernetes.io/cloudflare-proxied=false (or absent)
}

# Deployment 2: Cloudflare proxied (orange cloud ON)
resource "helm_release" "external_dns_proxied" {
  name  = "external-dns-cloudflare-proxy"
  # ... cloudflare provider, proxied
  set { name = "cloudflare.proxied", value = "true" }
  set { name = "txtOwnerId",         value = "${var.cluster_name}-proxy" }
  set { name = "annotationFilter",   value = "external-dns.alpha.kubernetes.io/cloudflare-proxied=true" }
}
```

#### Firewall Rules

Based on production cluster firewall rules from `heysarver/terraform-control/hzr-rke2-prod/firewalls.tf`:

**Inbound (control plane nodes):**
- ICMP — open
- TCP 22 (SSH) — open (or restricted to Tailscale/trusted CIDRs when `enable_firewall = true`)
- TCP 6443 (Kubernetes API) — open (or restricted to LB subnet)
- TCP 9345 (RKE2 supervisor) — restricted to private network CIDR
- TCP 10250 (kubelet) — restricted to private network CIDR
- TCP 2379-2380 (etcd) — restricted to private network CIDR
- UDP 8472 (Cilium VXLAN) — restricted to private network CIDR

**Inbound (worker nodes):**
- ICMP — open
- TCP 22 (SSH) — open (or restricted)
- TCP 10250 (kubelet) — restricted to private network CIDR
- TCP 30000-32767 (NodePort) — open (or configurable)
- UDP 8472 (Cilium VXLAN) — restricted to private network CIDR

**Outbound:** All outbound allowed (default Hetzner behavior).

### Research Insights: Firewall & Network Security

**HIGH — SSH should default to restricted, not open:**

Defaulting TCP 22 to `0.0.0.0/0` is insecure. Add a `trusted_ssh_cidrs` variable:

```hcl
variable "trusted_ssh_cidrs" {
  description = "CIDRs allowed to SSH to nodes. Empty list = deny all. Use Tailscale CGNAT (100.64.0.0/10) when enable_tailscale_nodes=true."
  type        = list(string)
  default     = []  # default: SSH blocked; callers must opt in
}
```

If `trusted_ssh_cidrs` is empty and `enable_tailscale_nodes = true`, the module should automatically include `["100.64.0.0/10"]` in the firewall rule.

**HIGH — API server 6443 should support IP restriction:**

Add a `kube_api_allowed_cidrs` variable (default open for backwards compatibility, but document the recommendation):

```hcl
variable "kube_api_allowed_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API server (port 6443). Default 0.0.0.0/0 — restrict in production to office/VPN CIDRs or Tailscale CGNAT."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}
```

**MEDIUM — NodePort should default to closed:**

Port range 30000-32767 open to the internet exposes all NodePort services. Add a `nodeport_allowed_cidrs` variable (default: `[]` = closed):

```hcl
variable "nodeport_allowed_cidrs" {
  description = "CIDRs allowed to reach NodePort services (TCP 30000-32767). Default empty = closed. Most use cases should use Hetzner LB via CCM instead."
  type        = list(string)
  default     = []
}
```

**MEDIUM — Block Hetzner metadata API from pods (via CiliumNetworkPolicy):**

The Hetzner metadata service at `169.254.169.254` is accessible to any pod by default. Cloud-init secrets (including the RKE2 join token and Tailscale auth key) are readable via this endpoint. Deploy a cluster-wide policy immediately after Cilium is ready:

```hcl
resource "kubernetes_manifest" "block_metadata_api" {
  depends_on = [helm_release.cilium]
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumClusterwideNetworkPolicy"
    metadata   = { name = "block-metadata-api" }
    spec = {
      endpointSelector = {}  # matches all endpoints
      egressDeny = [{
        toCIDR = ["169.254.169.254/32"]
      }]
    }
  }
}
```

**Note on etcd CIDR validation:** Add a `precondition` on `cluster_subnet_cidr` to reject CIDR blocks larger than `/16`. An overly broad CIDR (e.g. `10.0.0.0/8`) makes firewall rules for etcd effectively permissive across the entire Hetzner project.

#### Sensitive Variable Handling

All secret inputs use `sensitive = true`. No secrets embedded in resource names, tags, or non-sensitive outputs. Template rendering with `sensitive()` wrapper where needed. The `kubeconfig` and `rke2_token` outputs are `sensitive = true`. Callers source secrets from env vars (`TF_VAR_hcloud_token`, etc.) or a secrets manager.

### Research Insights: Sensitive Variables & State Security

**CRITICAL — kubeconfig and rke2_token in Terraform state are plaintext:**

`sensitive = true` prevents terminal output only. Both values are stored as plaintext in the state file. The kubeconfig contains cluster-admin credentials (CA cert + client cert + private key). Anyone with read access to state has full cluster-admin.

Required actions:
1. **Document prominently:** State backend must be encrypted. Acceptable backends: Terraform Cloud/Enterprise, S3 + SSE-KMS, GCS + CMEK. Add example backend configuration to `examples/minimal/` and `examples/full/`.
2. **`rke2_token` must not be in outputs by default.** The module consumes it internally via `templatefile()`. Expose it behind an opt-in variable:

```hcl
variable "expose_rke2_token" {
  description = "Output the RKE2 cluster join token. Default false — only enable if callers need it outside this module."
  type        = bool
  default     = false
}

output "rke2_token" {
  description = "RKE2 cluster join token. Only exposed when expose_rke2_token=true."
  value       = var.expose_rke2_token ? random_password.rke2_token.result : null
  sensitive   = true
}
```

3. **Add `lifecycle { prevent_destroy = true }` on `random_password.rke2_token`** to prevent accidental token rotation that would invalidate all node cloud-inits.

**HIGH — Separate hcloud token surface per component:**

Add three separate token variables, even if callers initially use the same value:

```hcl
variable "hcloud_ccm_token"        { sensitive = true; description = "Hetzner token for Cloud Controller Manager" }
variable "hcloud_csi_token"        { sensitive = true; description = "Hetzner token for CSI driver" }
variable "hcloud_autoscaler_token" { sensitive = true; description = "Hetzner token for Cluster Autoscaler" }
```

This future-proofs the module for when Hetzner adds granular token scopes, and ensures callers think about blast radius. Document the minimum required permissions for each component.

**HIGH — Split Tailscale auth keys:**

The operator and node-level Tailscale enrollments have different trust requirements (in-cluster services vs. infrastructure nodes) and should use separate ACL tags:

```hcl
variable "tailscale_operator_auth_key" {
  description = "Tailscale auth key for the Kubernetes operator. Tag: tag:k8s-operator"
  type        = string
  sensitive   = true
  default     = null
}

variable "tailscale_node_auth_key" {
  description = "Tailscale auth key for node-level enrollment. Tag: tag:k8s-node. Use ephemeral reusable keys."
  type        = string
  sensitive   = true
  default     = null
}
```

**HIGH — Store autoscaler secrets in Kubernetes Secret, not plain env var:**

The autoscaler Deployment should reference the `HCLOUD_CLUSTER_CONFIG` (which contains the RKE2 join token) via a Kubernetes Secret + `secretKeyRef`, not a plain env var on the Deployment spec. Otherwise, the join token is visible to anyone with `kubectl get deployment -o yaml` in `kube-system`.

**MEDIUM — Enable RKE2 secrets encryption at rest:**

Add to all control plane nodes' `config.yaml`:
```yaml
secrets-encryption: true
```

This encrypts Kubernetes Secret objects at rest in etcd using AES-CBC, ensuring the Hetzner API tokens stored in CCM/CSI/autoscaler Secrets are encrypted on disk.

**MEDIUM — Scrub cloud-init logs post-bootstrap:**

Cloud-init writes a full execution log to `/var/log/cloud-init-output.log` including all rendered template values (tokens, auth keys). Add a cleanup step:

```yaml
runcmd:
  # ... (all other setup commands) ...
  - truncate -s 0 /var/log/cloud-init-output.log
  - truncate -s 0 /var/log/cloud-init.log
```

#### Node-Level Tailscale (cloud-init security)

Tailscale auth key injection via cloud-init is handled using **ephemeral, one-time-use** auth keys. The Tailscale auth key variable is marked `sensitive = true`. The cloud-init snippet uses `tailscale up --auth-key <key> --hostname <hostname>` — the key is consumed once and cannot be reused. This prevents replay attacks even if the cloud-init is leaked via Hetzner metadata API.

---

### Implementation Phases

#### Phase 1: Core Infrastructure (networking + compute)

**Goal:** `terraform apply` provisions nodes and outputs a working kubeconfig. No add-ons yet.

**Files to create:**

- `versions.tf` — Terraform >= 1.5, providers: `hetznercloud/hcloud >= 1.58.0`, `hashicorp/random >= 3.6`
- `provider.tf` — Empty `provider "hcloud" {}` stub; caller sets `HCLOUD_TOKEN`
- `variables.tf` — Core variables: `cluster_name`, `hcloud_token`, `location`, `ssh_key_names`, `rke2_version`, `control_plane_server_type`, `node_pools` (list of objects), `network_cidr`, `cluster_subnet_cidr`
- `locals.tf` — Name prefix, cloud-init template rendering
- `outputs.tf` — `kubeconfig` (sensitive), `cluster_name`, `control_plane_lb_ip`, `private_network_id`, `rke2_token` (sensitive)
- `main.tf` — Calls `module.networking` and `module.node_pools`
- `modules/networking/main.tf` — `hcloud_network`, `hcloud_network_subnet`, `hcloud_placement_group` (type: spread), `hcloud_load_balancer`, `hcloud_load_balancer_network`, `hcloud_load_balancer_target`, `hcloud_load_balancer_service` (6443)
- `modules/networking/firewalls.tf` — Optional `hcloud_firewall` + `hcloud_firewall_attachment`
- `modules/networking/variables.tf` + `outputs.tf`
- `modules/node-pool/main.tf` — `hcloud_server` with `user_data`, optional `hcloud_volume` + `hcloud_volume_attachment`, `hcloud_server_network` (private net attachment)
- `modules/node-pool/templates/cp-init.yaml.tpl` — RKE2 server cloud-init
- `modules/node-pool/templates/worker-init.yaml.tpl` — RKE2 agent cloud-init
- `modules/node-pool/variables.tf` + `outputs.tf`

**Success criteria:**
- `terraform apply` on `examples/minimal/` completes without error
- `kubectl --kubeconfig <output> get nodes` shows 3 control plane + N worker nodes in Ready state
- RKE2 API server reachable via LB IP on port 6443

#### Phase 2: Required Hetzner Add-ons (CCM, CSI, Cilium)

**Goal:** Cluster has functioning LB provisioning, block storage, and eBPF networking.

**Files to create:**

- `modules/addons/main.tf` — Provider config block using kubeconfig, orchestration `depends_on`
- `modules/addons/variables.tf` — All `enable_*` flags (CCM, CSI, Cilium default true)
- `modules/addons/ccm.tf` — `helm_release.hcloud_ccm` from `charts.hetzner.cloud`, namespace `kube-system`, sets `networking.enabled=true` + LB annotations
- `modules/addons/csi.tf` — `helm_release.hcloud_csi` from `charts.hetzner.cloud`, namespace `kube-system`, depends on CCM
- `modules/addons/cilium.tf` — `helm_release.cilium` from `helm.cilium.io`, VXLAN mode, `kubeProxyReplacement: false`, Hubble enabled
- Update `main.tf` to include `module.addons` with `depends_on = [module.node_pools]`
- Add `versions.tf` provider requirements: `hashicorp/helm >= 2.12`, `hashicorp/kubernetes >= 2.27`

**Success criteria:**
- `kubectl get pods -n kube-system` shows CCM, CSI, and Cilium pods Running
- `kubectl get nodes -o wide` shows node internal IPs from the private network (CCM sets these)
- `kubectl apply -f test-pvc.yaml` provisions a Hetzner block volume (CSI working)
- `kubectl exec test-pod -- cilium status` or `hubble observe` shows Cilium running

#### Phase 3: Networking Add-ons (external-dns, cert-manager, ingress)

**Goal:** DNS is automated, TLS is automated, and ingress is operational.

**Files to create:**

- `modules/addons/external_dns.tf` — Two `helm_release` resources: `external-dns-cloudflare` and `external-dns-cloudflare-proxy`; requires `cloudflare_api_token` + `cloudflare_zone_id` variables; depends on ingress LB
- `modules/addons/cert_manager.tf` — `helm_release.cert_manager` (cert-manager chart with `installCRDs: true`), `kubectl_manifest.cluster_issuer` (Cloudflare DNS-01 `ClusterIssuer` for `letsencrypt-prod-dns`)
- `modules/addons/ingress.tf` — Conditional on `ingress_type`: either Traefik (`helm_release.traefik`) with Gateway API CRDs + GatewayClass, or NGINX (`helm_release.nginx_ingress`); installs Gateway API CRDs regardless
- Update `modules/addons/variables.tf` with: `enable_external_dns`, `cloudflare_api_token`, `cloudflare_zone_id`, `enable_cert_manager`, `enable_ingress`, `ingress_type` (traefik/nginx), `ingress_lb_location`

**Traefik + Gateway API specifics:**
- Install Gateway API CRDs from standard channel: `kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml` (via `kubernetes_manifest` resources or a `null_resource` exec)
- Configure Traefik Helm values: `providers.kubernetesGateway.enabled: true`, `experimental.kubernetesGateway.enabled: true`
- Create `GatewayClass` resource with `controllerName: traefik.io/gateway-controller`
- Create a default `Gateway` resource in the `kube-system` or `default` namespace

**Success criteria:**
- `kubectl get gateways` shows a provisioned Gateway (Traefik mode)
- `kubectl get ingressclass` shows `nginx` or `traefik` class
- Deploying a test `Ingress` with external-dns annotation auto-creates DNS record in Cloudflare
- cert-manager issues a test certificate via DNS-01 challenge

#### Phase 4: Storage (Longhorn)

**Goal:** Distributed storage with RWO and RWX support, optional dedicated data volumes.

**Files to create:**

- `modules/addons/longhorn.tf` — `helm_release.longhorn` from `longhorn.io` Helm repo; sets `defaultSettings.defaultDataPath`; creates StorageClasses: `longhorn` (default), `longhorn-ha` (2 replicas), `longhorn-rwx` (NFS access mode); optional `helm_release.nfs_server` when `longhorn_rwx_mode = "external"`
- Update `modules/node-pool/main.tf` with `hcloud_volume` + `hcloud_volume_attachment` + cloud-init volume format/mount step
- Update `modules/node-pool/templates/worker-init.yaml.tpl` with conditional volume formatting (mkfs.ext4 + fstab mount at `/mnt/longhorn`)
- Update `modules/addons/variables.tf` with: `enable_longhorn`, `longhorn_version`, `longhorn_rwx_mode`, `longhorn_default_replicas`

**Success criteria:**
- `kubectl get sc` shows `longhorn` (default), `longhorn-ha`, `longhorn-rwx`, `hcloud-volumes` StorageClasses
- RWO PVC binds and pod mounts successfully
- RWX PVC binds and multiple pods can mount simultaneously
- On nodes with `longhorn_volume_size > 0`, `df -h /mnt/longhorn` shows the dedicated volume

#### Phase 5: Autoscaling

**Goal:** Worker pools can scale automatically based on pending pod pressure.

**Files to create:**

- `modules/addons/autoscaler.tf` — `helm_release.cluster_autoscaler` from `https://kubernetes.github.io/autoscaler`, chart `9.46.6`, image `registry.k8s.io/autoscaling/cluster-autoscaler:v1.32.7`; environment vars via Kubernetes Secret: `HCLOUD_TOKEN`, `HCLOUD_CLUSTER_CONFIG` (base64 JSON with per-pool nodeConfigs — **not** `HCLOUD_CLOUD_INIT`), `HCLOUD_NETWORK`; `--nodes` flags generated from autoscaled pool configurations; `autoscaler_rbac_level` variable controls ClusterRole scope
- Update `modules/addons/variables.tf` with: `enable_cluster_autoscaler`, `autoscaler_node_groups` (list of min/max/server_type/location/pool_name), `autoscaler_rbac_level`, `hcloud_autoscaler_token` (separate from ccm/csi token)
- Update `outputs.tf` to expose `autoscaled_pool_names`

**Success criteria:**
- `kubectl get pods -n kube-system | grep autoscaler` shows Running
- Deploying a workload that exceeds current worker capacity triggers scale-up within ~2 min
- Removing workload triggers scale-down after 10 min (default cooldown)

#### Phase 6: Advanced Add-ons (Flux, monitoring, Tailscale)

**Goal:** GitOps bootstrap, observability, and Tailscale connectivity.

**Files to create:**

- `modules/addons/flux.tf` — `flux_bootstrap_git.this` resource using `fluxcd/flux` provider; auto or manual deploy key mode based on `flux_deploy_key_mode`; when `auto`: `tls_private_key` resource + GitHub API call via `github` provider to register deploy key; requires `flux_github_org`, `flux_github_repo`, `flux_branch`, `flux_path`, `github_token` variables; `depends_on = [helm_release.hcloud_ccm, helm_release.hcloud_csi]`
- `modules/addons/monitoring.tf` — `helm_release.kube_prometheus_stack` from `prometheus-community`; `grafana.ingress.hosts` configurable; depends on ingress; **`timeout = 600`** required (large chart with many CRDs and pods)
- `modules/addons/tailscale.tf` — `helm_release.tailscale_operator` from official Tailscale Helm repo; requires `tailscale_auth_key`
- Update `modules/node-pool/templates/tailscale-init.sh.tpl` — Tailscale install script for node-level: `curl -fsSL https://tailscale.com/install.sh | sh && tailscale up --auth-key ${tailscale_auth_key} --hostname ${hostname} --ephemeral`
- Update `modules/node-pool/variables.tf` with: `enable_tailscale_nodes`, `tailscale_auth_key`
- Update `modules/addons/variables.tf` with: `enable_flux`, `flux_deploy_key_mode`, `flux_github_org`, `flux_github_repo`, `flux_branch`, `flux_path`, `github_token`, `enable_monitoring`, `grafana_hostname`, `enable_tailscale_operator`, `tailscale_auth_key`

**Success criteria:**
- Flux: `flux get sources git` shows the configured repo reconciling; GitOps-managed resources deploy within one reconcile interval
- Monitoring: Grafana UI accessible at `grafana_hostname`; `kubectl get pods -n monitoring` shows stack Running
- Tailscale operator: `kubectl get tailscalePods` (or equivalent) shows cluster nodes in Tailnet
- Node-level Tailscale: new nodes appear in Tailscale admin with correct hostnames

#### Phase 7: Examples + Documentation

**Files to create:**

- `examples/minimal/main.tf` — Root module call with only required vars, CCM+CSI enabled, no other add-ons
- `examples/minimal/variables.tf` + `outputs.tf`
- `examples/full/main.tf` — Root module call with all add-ons enabled, mirrors `rke2-primary` conventions
- `examples/full/variables.tf` + `outputs.tf`
- `README.md` — Full module documentation: inputs table, outputs table, usage examples, add-on dependency notes
- `CHANGELOG.md` — Initial v0.1.0 entry

---

## Alternative Approaches Considered

| Approach | Why Rejected |
|---|---|
| Fork kube-hetzner | K3s only, not RKE2. Different bootstrap model, would require significant rewrite. |
| Use wenzel-felix/terraform-hcloud-rke2 as base | No autoscaler, no add-on system, manual upgrade process. Would require more rewriting than building from scratch given our full add-on requirements. |
| Single-file monolith | Non-composable. Can't reuse node-pool logic for CP and workers. Hard to test. |
| RKE2 native HelmChartConfig for add-ons | Limited control over values, can't use `depends_on`. Helm provider gives full control. |
| Talos Linux | Packer pre-build required, learning curve, no Ubuntu familiarity. Out of scope per requirements. |

---

## System-Wide Impact

### Interaction Graph

```
terraform apply
  → hcloud_network + subnet + placement_group
  → hcloud_load_balancer (API LB)
  → hcloud_server × 3 (control-plane) [user_data = cloud-init → RKE2 server mode]
    → hcloud_server_network (attaches to private net)
    → hcloud_load_balancer_target (registers CP nodes)
  → [wait: RKE2 API server ready, kubeconfig available]
  → hcloud_server × N (worker pools) [user_data = cloud-init → RKE2 agent mode]
    → optional: hcloud_volume + hcloud_volume_attachment per worker
  → helm_release.cilium (CNI — must be first, nodes NotReady without CNI)
  → helm_release.hcloud_ccm (enables LoadBalancer services)
  → helm_release.hcloud_csi (enables PersistentVolumes)
  → helm_release.cert_manager
  → helm_release.external_dns_x2
  → helm_release.traefik (or nginx) → triggers hcloud LB creation via CCM
  → helm_release.longhorn → reads attached volumes via /dev/disk/by-id/
  → helm_release.cluster_autoscaler
  → helm_release.monitoring
  → helm_release.tailscale_operator
  → flux_bootstrap_git (writes to GitHub repo, installs Flux controllers)
```

### Error & Failure Propagation

- **Cloud-init failure on CP nodes**: RKE2 fails to start. Terraform remote-exec health check times out. Terraform apply fails with timeout. Node remains in Hetzner. Manual cleanup of `hcloud_server` required before re-apply.
- **Cilium not deployed before CCM**: Nodes stay in `NotReady` state. CCM may fail to set node addresses. Ordering must be enforced.
- **kubeProxyReplacement: true on Cilium**: Breaks CCM LoadBalancer service reconciliation silently (LBs provision but traffic doesn't route). Services stay in Pending state or route incorrectly. **Mitigation**: Pin `kubeProxyReplacement: false` in Cilium values; document the constraint.
- **Longhorn deployed before volumes attached**: Longhorn uses OS disk instead of dedicated volume even when `longhorn_data_volume_size > 0`. **Mitigation**: `depends_on` in `addons` module references `node_pool.volume_attachment_ids` output.
- **Flux bootstrap git push fails**: Flux provider returns error. Terraform apply fails. The cluster and all non-Flux add-ons are already provisioned (partial success). Re-running apply retries only the Flux resource. **Mitigation**: Separate `enable_flux = true/false`; document partial apply recovery.
- **Tailscale node-level auth key used more than once**: Auth key should be ephemeral. If the same key is used for multiple nodes, and it's set to one-time-use, only the first node joins. **Mitigation**: Use reusable (but scoped) auth key, or generate per-node ephemeral keys via Tailscale API in Terraform.

### State Lifecycle Risks

- **Cluster token rotation**: The `random_password.rke2_token` is created once. Rotating it requires re-provisioning all nodes. Document: do not change the token after initial apply.
- **Node pool scale-down via Terraform**: Reducing `count` on a fixed node pool removes specific servers (index-based). If that node has Longhorn replicas, data loss risk. **Mitigation**: Document: drain nodes before scaling down; Longhorn replica count should be <= number of worker nodes.
- **hcloud_volume deletion on pool removal**: Volumes are attached to servers. If the server is deleted and the volume is not, it becomes orphaned (Hetzner charges apply). **Mitigation**: `depends_on` + document cleanup; consider lifecycle policy in examples.
- **Autoscaled nodes not in Terraform state**: CA-provisioned nodes are managed by the autoscaler, not Terraform state. Running `terraform apply` after CA scales up will show drift on the node pool count. **Mitigation**: For autoscaled pools, set `lifecycle { ignore_changes = [count] }` on the `hcloud_server` resource within the node-pool module when `scaling_mode = "autoscaled"`.

### API Surface Parity

- The `node-pool` module is reused for both control-plane and worker pools. CP-specific behavior (cloud-init template, placement group, LB target attachment) is gate via a `role` variable (`server` vs `agent`).
- The `addons` module is called once from root with all flags. Each add-on is independently toggleable; disabling one should not affect others.
- `examples/minimal` and `examples/full` serve as integration tests — both must work independently.

### Integration Test Scenarios

1. **Single apply — full stack**: `examples/full` applies end-to-end with all add-ons. Verify: kubeconfig works, all pods Running, Longhorn PVC binds, external-dns creates Cloudflare record.
2. **Idempotency**: Run `terraform apply` twice on the same state. Second apply should make zero changes.
3. **Worker pool scaling (fixed)**: Change `worker_count` from 2 → 3. Apply adds one server and it joins the cluster. Longhorn rebalances replica.
4. **Autoscaled pool stress test**: Deploy HPA workload exceeding min node capacity. Verify CA provisions a new node within 2 minutes. Remove workload; verify CA removes node after 10-minute cooldown.
5. **Add-on disable**: Start with full stack. Set `enable_longhorn = false`. Apply should destroy Longhorn helm_release without affecting other add-ons.

---

## Acceptance Criteria

### Functional Requirements (from origin doc)

- [ ] R1: 3-node HA control plane, spread placement group across Hetzner zones
- [ ] R2: Variable number of worker pools, each independently configurable
- [ ] R3: Private network always provisioned, CIDR configurable
- [ ] R4: Ubuntu 24.04 LTS default OS, configurable via variable
- [ ] R5: `assign_public_ip` per pool; default: workers off, CP on
- [ ] R6: `rke2_version` variable with pinned default
- [ ] R7: SSH keys passed as Hetzner resource IDs/names
- [ ] R8: Cilium CNI only; Canal disabled via `cni: none` in RKE2 config
- [ ] R9: Hetzner LB for API server (6443) always provisioned; LB for ingress when ingress enabled
- [ ] R10–R12: Per-pool autoscaling with CA; fixed and autoscaled pools coexist
- [ ] R13: Optional Hetzner Firewall with configurable rules and production-derived defaults
- [ ] R14: All sensitive variables use `sensitive = true`; no secrets in templates or non-sensitive outputs
- [ ] R15: CCM + CSI default-on; Hetzner LB provisioning and block storage working
- [ ] R16: Two external-dns deployments (proxied + non-proxied) matching `rke2-primary` convention
- [ ] R17: cert-manager with Cloudflare DNS-01 ClusterIssuer (`letsencrypt-prod-dns`)
- [ ] R18: Ingress via Traefik + Gateway API CRDs (default) or NGINX; Gateway API CRDs always installed when ingress enabled
- [ ] R19: Longhorn with RWO + RWX StorageClasses; `longhorn_rwx_mode` variable; optional dedicated data volumes
- [ ] R20: Flux CD bootstrap via `fluxcd/flux` provider; `flux_deploy_key_mode = auto | manual`
- [ ] R21: kube-prometheus-stack optional; Grafana hostname configurable
- [ ] R22: Tailscale operator optional; `tailscale_auth_key` variable
- [ ] R23: Node-level Tailscale optional; ephemeral auth keys via cloud-init
- [ ] R24: Outputs: `kubeconfig` (sensitive), `cluster_name`, `control_plane_lb_ip`, `node_pool_names`, `private_network_id`

### Non-Functional Requirements

- [ ] `terraform plan` on an existing cluster shows zero changes (idempotency)
- [ ] No hardcoded secrets anywhere in the module code
- [ ] Terraform >= 1.5 required; no features from 1.6+ used
- [ ] Module can be called from an external root module as `module "cluster" { source = "github.com/sarverenterprises/terraform-hcloud-rke2-cluster" }`
- [ ] `examples/minimal` and `examples/full` both apply successfully to real Hetzner accounts

### Quality Gates

- [ ] All variables have `description` fields
- [ ] All outputs have `description` fields
- [ ] `sensitive = true` on: `hcloud_token`, `cloudflare_api_token`, `github_token`, `tailscale_auth_key`, `rke2_token`, `kubeconfig`
- [ ] README documents all input variables, outputs, and add-on dependencies
- [ ] At least one working example in `examples/`

---

## Success Metrics

- A new Hetzner RKE2 cluster (matching `rke2-primary` feature set) provisions in a single `terraform apply` run
- Zero manual `kubectl` commands required post-apply
- `examples/full` output cluster passes all acceptance criteria with all pods Running
- Module is reused for at least one additional cluster deployment within 90 days

---

## Dependencies & Prerequisites

- Hetzner Cloud project with API token (write permissions)
- Cloudflare API token with `Zone:DNS:Edit` permission (for external-dns + cert-manager)
- GitHub PAT with `repo` scope (for Flux deploy key registration when `flux_deploy_key_mode = auto`)
- Tailscale auth key (when Tailscale add-ons enabled)
- Terraform >= 1.5 installed locally
- `hcloud` CLI for debugging (optional but useful)

### Provider Versions to Pin

| Provider | Source | Version constraint |
|---|---|---|
| hetznercloud/hcloud | hetznercloud/hcloud | >= 1.58.0 |
| hashicorp/helm | hashicorp/helm | >= 2.12.0 |
| hashicorp/kubernetes | hashicorp/kubernetes | >= 2.27.0 |
| hashicorp/random | hashicorp/random | >= 3.6.0 |
| hashicorp/tls | hashicorp/tls | >= 4.0.0 |
| fluxcd/flux | fluxcd/flux | >= 1.3.0 (conditional) |
| integrations/github | integrations/github | >= 6.0.0 (conditional, for deploy key) |

### Default Version Pins (Research-Informed)

| Component | Default value | Notes |
|---|---|---|
| `rke2_version` | `v1.32.13+rke2r1` | Latest stable as of Q1 2026; update at module release |
| `cilium_chart_version` | `~> 1.19.0` | Current stable (1.19.1); was 1.17 in initial plan — updated per research |
| `hcloud_ccm_chart_version` | `~> 1.21` | Latest hcloud-cloud-controller-manager chart (v1.30.1 app) |
| `hcloud_csi_chart_version` | `~> 2.9` | Latest hcloud-csi chart (v2.20.0 app) |
| `longhorn_chart_version` | `~> 1.7` | Latest Longhorn 1.7.x |
| `cert_manager_chart_version` | `~> 1.16` | Latest cert-manager 1.16.x |
| `external_dns_chart_version` | `~> 1.14` | Latest external-dns chart |
| `traefik_chart_version` | `~> 32.0` | Latest Traefik chart (v3.x) |
| `flux_version` | `~> 2.4` | Latest Flux 2.x |
| `cluster_autoscaler_chart_version` | `9.46.6` | Matches appVersion 1.32.0; from `kubernetes.github.io/autoscaler` |
| `cluster_autoscaler_image_tag` | `v1.32.7` | Must match cluster K8s minor version |

---

## Risk Analysis & Mitigation

| Risk | Severity | Mitigation |
|---|---|---|
| kubeconfig + rke2_token in plaintext Terraform state | **Critical** | Require encrypted remote state backend; document in README; add example backend config |
| Cilium kube-proxy replacement breaks CCM LBs | High | Pin `kubeProxyReplacement: false`; document constraint; add comment in cilium.tf |
| Hetzner metadata API (169.254.169.254) accessible to all pods | High | Deploy `CiliumClusterwideNetworkPolicy` blocking egress to 169.254.169.254/32 immediately after Cilium |
| Single hcloud_token for CCM, CSI, and autoscaler | High | Expose separate `hcloud_ccm_token`, `hcloud_csi_token`, `hcloud_autoscaler_token` variables |
| SSH TCP 22 open to 0.0.0.0/0 by default | High | Default to `trusted_ssh_cidrs = []` (closed); require explicit opt-in |
| API server 6443 on public LB with no IP restriction | High | Add `kube_api_allowed_cidrs` variable; document Tailscale alternative for API access |
| Single reusable Tailscale auth key across all nodes | High | Split into `tailscale_operator_auth_key` + `tailscale_node_auth_key`; plan for per-node ephemeral keys via Tailscale Terraform provider |
| Autoscaler cloud-init join token in Deployment env var | High | Store `HCLOUD_CLUSTER_CONFIG` in Kubernetes Secret; reference via `secretKeyRef` |
| Cloud-init race condition (nodes ready before CNI) | Medium | Add `cilium_wait_ready` null_resource with `kubectl -n kube-system wait pod -l k8s-app=cilium --for=condition=Ready` |
| cloud-init logs persist secrets to disk | Medium | Add `truncate -s 0` step for cloud-init logs at end of runcmd |
| NodePort 30000-32767 open to 0.0.0.0/0 by default | Medium | Default `nodeport_allowed_cidrs = []` (closed); prefer CCM LB |
| Autoscaler cloud-init token staleness | Medium | `rke2_token` is static after create; autoscaler always has correct cloud-init since it's from Terraform locals |
| Longhorn deployed before data volumes mounted | Medium | `depends_on` in addons module on node_pool volume attachment outputs |
| Flux bootstrap race with cluster being unstable | Low-Medium | `depends_on = [helm_release.hcloud_ccm, helm_release.hcloud_csi, helm_release.cilium]`; Flux bootstraps last |
| Gateway API CRD version mismatch with Traefik | Low | Pin Gateway API CRD version alongside Traefik chart version; test together |

### Research Insights: Security Additions to Phases

**Phase 1 additions (core infrastructure):**
- Add `trusted_ssh_cidrs`, `kube_api_allowed_cidrs`, `nodeport_allowed_cidrs` variables to `variables.tf`
- Add `precondition` on `cluster_subnet_cidr` rejecting CIDR blocks larger than `/16`
- Add `lifecycle { prevent_destroy = true }` on `random_password.rke2_token`
- Change `expose_rke2_token` pattern — remove `rke2_token` from default outputs
- Add `secrets-encryption: true` to all CP node `config.yaml` templates

**Phase 2 additions (CCM/CSI/Cilium):**
- Deploy `CiliumClusterwideNetworkPolicy` blocking 169.254.169.254/32 immediately after Cilium

**Phase 5 additions (autoscaler):**
- Create `kubernetes_secret.autoscaler_credentials` containing `HCLOUD_TOKEN` + `HCLOUD_CLUSTER_CONFIG`
- Reference via `secretKeyRef` in autoscaler Deployment (not plain env var)

**Phase 7 additions (docs):**
- Add dedicated "Security" section to README: encrypted state backends, minimum token scopes, Cloudflare token creation instructions, GitHub PAT minimum scope
- Add example backend config (S3 + SSE-KMS or Terraform Cloud) to both examples

---

## Documentation Plan

- `README.md` — Complete rewrite: title, description, prerequisites, quick-start, all variables table, all outputs table, add-on dependency diagram, upgrade notes
- Inline variable/output descriptions — All variables and outputs must have meaningful `description` fields
- `examples/minimal/README.md` — How to use the minimal example
- `examples/full/README.md` — How to use the full example, prerequisites list
- Inline HCL comments — Non-obvious logic (especially Cilium kube-proxy constraint, CA cloud-init pattern, ordering deps)

---

## Outstanding Research to Resolve During Implementation

**Resolved by deepen-plan research:**

- ~~[Affects R6] RKE2 version~~ → **v1.32.13+rke2r1** confirmed
- ~~[Affects R8] Cilium chart version~~ → **1.19.1** (current stable), not ~> 1.17. `tunnel` key deprecated, use `routingMode + tunnelProtocol`.
- ~~[Affects R11] Autoscaler image tag~~ → **v1.32.7** for K8s 1.32; chart `9.46.6` from `kubernetes.github.io/autoscaler`
- ~~[Affects R11] HCLOUD_CLOUD_INIT vs HCLOUD_CLUSTER_CONFIG~~ → **`HCLOUD_CLUSTER_CONFIG`** is correct; `HCLOUD_CLOUD_INIT` is legacy single-pool only
- ~~[Affects R19] Hetzner SCSI volume path~~ → `/dev/disk/by-id/scsi-0HC_Volume_<volume-id>` confirmed
- ~~[Affects R23] Tailscale key approach~~ → Split into `tailscale_operator_auth_key` + `tailscale_node_auth_key`; use reusable ephemeral keys; future: per-node via `tailscale/tailscale` Terraform provider

**Still to resolve during implementation:**

- **[Affects R15]** Verify exact CCM Helm chart version from `charts.hetzner.cloud` at time of implementation (`helm search repo hcloud/hcloud-cloud-controller-manager`)
- **[Affects R18]** Verify Gateway API CRD version (standard-install.yaml release tag) compatible with Traefik v32.x chart — pin exact versions together
- **[Affects R23]** Evaluate adopting `tailscale/tailscale` Terraform provider for per-node ephemeral key generation instead of a shared reusable key

---

## Sources & References

### Origin

- **Origin document**: [`docs/brainstorms/2026-03-21-terraform-hcloud-rke2-cluster-requirements.md`](../brainstorms/2026-03-21-terraform-hcloud-rke2-cluster-requirements.md)
  - Key decisions carried forward: Cilium as only CNI (kubeProxyReplacement: false constraint), two external-dns deployments, Flux optional variable-gated, all secrets as sensitive variables

### Internal References

- Production cluster conventions: `~/.claude/CLAUDE_rke2-primary.md`
- Existing RKE2 module (conventions): `heysarver/terraform-hcloud-rke2` — provider pin `hetznercloud/hcloud >= 1.58.0`, `provider.tf` / `versions.tf` split
- Production cluster Terraform: `heysarver/terraform-control/hzr-rke2-prod/` — firewall rules, server types, network CIDRs
- Network baseline: `heysarver/terraform-control/hzr-infrastructure/` — `10.0.0.0/8` root network pattern

### External References

- Hetzner Cloud Terraform provider docs: `registry.terraform.io/providers/hetznercloud/hcloud/latest/docs`
- Hetzner Helm charts: `charts.hetzner.cloud` (CCM + CSI)
- Hetzner Cluster Autoscaler: `github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler/cloudprovider/hetzner`
- Cilium Helm chart: `helm.cilium.io` — confirm `kubeProxyReplacement: false` with hcloud-ccm
- Gateway API installation: `gateway-api.sigs.k8s.io` — standard channel CRDs
- Flux Terraform provider: `registry.terraform.io/providers/fluxcd/flux/latest/docs`
- Longhorn Helm chart: `charts.longhorn.io`
- kube-hetzner (K3s reference, patterns transferable): `github.com/kube-hetzner/terraform-hcloud-kube-hetzner`
