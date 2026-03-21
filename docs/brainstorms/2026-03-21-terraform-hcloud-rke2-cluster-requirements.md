---
date: 2026-03-21
topic: terraform-hcloud-rke2-cluster
---

# Terraform Hetzner Cloud RKE2 Cluster Module

## Problem Frame

The sarverenterprises/heysarver org deploys RKE2 Kubernetes clusters on Hetzner Cloud. Provisioning new clusters currently requires manual steps and lacks a repeatable, version-controlled foundation. This module provides a reusable, org-internal Terraform module that bootstraps full-featured RKE2 clusters on Hetzner Cloud with sensible defaults and opt-in add-ons aligned to the existing production cluster (`rke2-primary`) conventions.

---

## Requirements

### Cluster Topology

- R1. Module provisions a 3-node HA control plane using RKE2's embedded etcd. Control plane nodes are spread across Hetzner placement groups when available.
- R2. Module supports one or more worker node pools. Each pool is independently configurable (instance type, count, labels, taints, disk strategy).
- R3. All nodes are placed on a Hetzner private network (always provisioned by the module). The private network CIDR is configurable.

### Node Configuration

- R4. Ubuntu LTS (22.04/24.04, configurable) is the default OS. The active LTS version is a variable with a sensible default.
- R5. Each node pool independently configures whether nodes receive a public IP (`assign_public_ip` per pool). Default: public IP off for workers, on for control plane.
- R6. RKE2 version is a variable with a sensible default pinned at module release (e.g., `v1.31.x+rke2r1`).
- R7. SSH key(s) are passed as a variable (Hetzner resource IDs or names). Required input.

### Networking & CNI

- R8. CNI is **Cilium** (matching production cluster `rke2-primary`). Cilium is the only supported CNI. RKE2 is configured to disable its default Canal CNI.
- R9. Module provisions a Hetzner Load Balancer for the RKE2 API server (port 6443) and, if ingress is enabled, for ingress traffic.

### Autoscaling

- R10. Each worker pool is independently configured as either **fixed** (Terraform-managed count) or **autoscaled** (Cluster Autoscaler manages after initial bootstrap). Fixed and autoscaled pools may coexist in the same cluster.
- R11. For autoscaled pools, the module deploys the Kubernetes Cluster Autoscaler (Hetzner Cloud provider) with per-pool min/max node count configuration.

### Security

- R13. Hetzner Firewall creation is optional (`enable_firewall` variable). When enabled, the module creates a firewall with configurable inbound/outbound rules and sane defaults (RKE2 ports open between nodes, 6443 accessible from LB, everything else denied by default).
- R14. All sensitive inputs (Hetzner API token, Cloudflare token, etc.) are declared as `sensitive = true` Terraform variables. No secrets are embedded in templates or outputs.

### Add-ons (opt-in via `enable_*` variables; CCM + CSI default on)

- R15. **Hetzner CCM + CSI** (`enable_hcloud_ccm`, `enable_hcloud_csi`): Deploys Hetzner Cloud Controller Manager (Hetzner LB provisioning) and CSI driver (block storage `StorageClass`). Both default **on** — required for Hetzner integration.
- R16. **External-DNS / Cloudflare** (`enable_external_dns`): Deploys External-DNS configured for Cloudflare. Two deployments supported: proxied and non-proxied, matching `rke2-primary` conventions. Requires `cloudflare_api_token` and `cloudflare_zone_id` variables.
- R17. **Cert-Manager** (`enable_cert_manager`): Deploys cert-manager with a Cloudflare DNS-01 `ClusterIssuer` for Let's Encrypt production. Wildcard certificates supported.
- R18. **Ingress / Gateway API** (`enable_ingress`, `ingress_type`): Deploys either Traefik (default, with Gateway API CRDs and GatewayClass enabled) or NGINX Ingress Controller. Default: `traefik`. Installs Gateway API CRDs regardless of implementation.
- R19. **Longhorn** (`enable_longhorn`): Deploys Longhorn distributed storage. Configures `StorageClass` resources for RWO and RWX (NFS) access modes. RWX backend is configurable via `longhorn_rwx_mode = builtin | external` (default `builtin`, using Longhorn's built-in share manager; `external` deploys a separate NFS server). Per-pool optional dedicated Hetzner block volume attachment for Longhorn data (`longhorn_data_volume_size` per pool, 0 = use OS disk folder).
- R20. **Flux CD** (`enable_flux`): Optionally bootstraps Flux CD using the fluxcd/flux Terraform provider. Requires `flux_github_org`, `flux_github_repo`, `flux_branch`, `flux_path`, and a GitHub token variable. Flux version configurable.
- R21. **kube-prometheus-stack** (`enable_monitoring`): Optionally deploys Prometheus, Alertmanager, and Grafana via kube-prometheus-stack Helm chart. Grafana hostname configurable for external-dns/cert-manager integration.
- R22. **Tailscale** (`enable_tailscale_operator`): Optionally deploys the Tailscale Kubernetes operator to the cluster. Requires `tailscale_auth_key` variable.
- R23. **Node-level Tailscale** (`enable_tailscale_nodes`): Optionally installs Tailscale on each node's OS via cloud-init. Provides VPN mesh SSH access to nodes without requiring public IPs.

### Outputs

- R24. Module outputs: `kubeconfig` (sensitive string), `cluster_name`, `control_plane_lb_ip`, `node_pool_names`, `private_network_id`. The `kubeconfig` output is marked `sensitive = true`; callers write it to disk or pass it to `helm`/`kubectl` providers.

### Module Structure

- R26. Module is organized with a root module and optional submodules: `modules/node-pool`, `modules/addons`, `modules/networking`. Root module composes these.
- R27. All Helm-based add-on deployments use the `hashicorp/helm` provider scoped to the provisioned cluster (kubeconfig from cluster output).
- R28. Module requires Terraform >= 1.5. Providers: `hetznercloud/hcloud`, `hashicorp/helm`, `hashicorp/kubernetes`, `fluxcd/flux` (when Flux enabled).

---

## Success Criteria

- A new RKE2 cluster on Hetzner can be fully provisioned with a single `terraform apply`, including all enabled add-ons, in a reproducible way.
- The module produces a working kubeconfig without any manual post-provisioning steps. When relevant add-ons are enabled, Longhorn storage, external-dns-managed DNS, and TLS-terminated ingress also work without manual intervention.
- New clusters provisioned by this module mirror the conventions of `rke2-primary` (Cilium CNI, two Cloudflare external-dns deployments, cert-manager with DNS-01, Longhorn storage classes).
- Module is idempotent: re-running `terraform apply` after initial creation makes no unintended changes.
- Each add-on is independently toggleable. A minimal cluster (CCM + CSI only) and a fully-featured cluster both work.

---

## Scope Boundaries

- Module is **not** published to the public Terraform Registry. It is org-internal.
- ArgoCD bootstrapping is **out of scope** — the existing `rke2-primary` is ArgoCD-only; new clusters optionally use Flux.
- External secrets management (Bitwarden / ESO) is **not bootstrapped** by this module. Callers deploy it post-cluster via GitOps.
- CloudNativePG, Harbor, and other application-layer operators are **out of scope**.
- Packer/custom OS image creation is **out of scope** — module uses Hetzner-provided Ubuntu images.
- DNS zone or Cloudflare account management is **out of scope** — callers provide API tokens.

---

## Key Decisions

- **CNI: Cilium** — Production cluster (`rke2-primary`) uses Cilium. Hetzner Cloud private networks support Cilium's VXLAN/Geneve tunneling. BGP routing not available on Hetzner.
- **OS: Ubuntu LTS only** — Sufficient for RKE2, familiar ops tooling, strong cloud-init support. MicroOS/immutable OS deferred.
- **Traefik + Gateway API as default ingress** — New clusters adopt Gateway API (`gateway.networking.k8s.io`). Traefik is RKE2's bundled default and supports Gateway API v1. NGINX available as alternative for parity with existing `rke2-primary` (which uses `nginx` ingress class).
- **Always-on private network** — Required for Hetzner CCM to correctly set node internal IPs, and for Cilium encrypted pod networking.
- **Hetzner CCM + CSI default-on** — Required for cloud integration (LB provisioning, block storage). Treated as required infrastructure, not optional add-ons, despite the `enable_*` variable pattern.
- **Two external-dns deployments** — Matches `rke2-primary` pattern: one for Cloudflare-proxied (orange cloud on), one for DNS-only (orange cloud off). Controlled via annotation `external-dns.alpha.kubernetes.io/cloudflare-proxied`.
- **Tailscale: both operator and node-level** — Operator provides in-cluster Tailscale connectivity; node-level provides SSH access to nodes over Tailscale mesh, particularly useful when nodes have no public IPs.
- **Cluster Autoscaler RBAC: `autoscaler_rbac_level = minimal | upstream`** — Configurable via variable. Callers with strict security requirements choose `minimal`; default `upstream` tracks the standard ClusterRole shipped by upstream CA.
- **Longhorn RWX mode: `longhorn_rwx_mode = builtin | external`** — Default `builtin` (Longhorn share manager). `external` deploys a separate NFS server (e.g., nfs-ganesha). Configurable per-cluster.
- **Flux deploy key: `flux_deploy_key_mode = auto | manual`** — Default `auto`: module generates SSH keypair and registers it via GitHub API. `manual`: caller pre-registers deploy key and provides private key as variable.

---

## Dependencies / Assumptions

- Caller has a Hetzner Cloud project and API token with write access.
- Caller has a Cloudflare API token with DNS edit permissions (required when external-dns or cert-manager is enabled).
- Caller has a GitHub personal access token with repo permissions (required when Flux is enabled).
- Caller has a Tailscale auth key (required when Tailscale add-ons are enabled).
- Hetzner Cloud regions `ash`, `nbg1`, `fsn1`, `hel1` are the supported deployment targets. Default: `ash`.
- Module assumes Hetzner Cloud IPv4 + IPv6 dual-stack is available.

---

## Outstanding Questions

### Resolve Before Planning

_(None — all blocking questions resolved.)_

### Deferred to Planning

- [Affects R6][Needs research] What is the latest stable RKE2 release to use as the pinned default? Should it be `v1.31.x` or `v1.32.x`?
- [Affects R8][Needs research] Specific Cilium Helm chart version and configuration values for Hetzner Cloud (VXLAN mode, kube-proxy replacement, native routing vs. encapsulation).
- [Affects R11][Needs research] Hetzner Cloud Cluster Autoscaler image version and correct node group annotation format (`hcloud/node-group`).
- [Affects R15][Needs research] Current recommended Hetzner CCM and CSI Helm chart versions (2025 releases).
- [Affects R18][Technical] Traefik Gateway API configuration: which GatewayClass name, which Gateway resource to provision, and how to map to the Hetzner LB created by CCM.
- [Affects R19][Technical] Longhorn data disk attachment: `hcloud_volume` resource must be attached to each worker node before Longhorn is deployed. Ordering dependency in Terraform.
- [Affects R26][Technical] Submodule interface design: what inputs/outputs should `modules/node-pool` expose vs. what stays in the root module?
- [Affects R27][Technical] Helm provider scoping: `depends_on` ordering between cluster provisioning, CCM/CSI deployment, and subsequent add-on Helm releases.
- [Affects R23][Technical] Node-level Tailscale via cloud-init: cloud-init script must handle Tailscale auth key injection securely (avoid embedding in Hetzner server metadata). Consider using `tailscale up --auth-key` with a one-time use/ephemeral key.

---

## Next Steps

→ `/ce:plan` for structured implementation planning
