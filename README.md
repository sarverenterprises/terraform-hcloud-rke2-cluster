# terraform-hcloud-rke2-cluster

[![Terraform Registry](https://img.shields.io/badge/Terraform-Registry-7B42BC?logo=terraform)](https://registry.terraform.io/modules/sarverenterprises/rke2-cluster/hcloud)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A production-grade Terraform module that provisions fully functional [RKE2](https://docs.rke2.io/) Kubernetes clusters on [Hetzner Cloud](https://www.hetzner.com/cloud). The module mirrors the conventions of a production Hetzner + RKE2 setup and exposes all major add-ons through simple `enable_*` variables.

---

## Features

- **RKE2 HA control plane** — 3-node control plane with embedded etcd, fronted by a Hetzner Load Balancer
- **Hetzner CCM** — Cloud Controller Manager for automatic LoadBalancer provisioning
- **Hetzner CSI** — Container Storage Interface driver for block PersistentVolumes
- **Cilium CNI** — eBPF-based networking in VXLAN tunnel mode with MTU 1400 (1450 Hetzner private NIC − 50 VXLAN overhead)
- **External-DNS** — Dual Cloudflare deployments (proxied + DNS-only) for automatic DNS record management
- **cert-manager** — Automatic TLS certificates via Cloudflare DNS-01 ClusterIssuer
- **Traefik / NGINX ingress** — Gateway API CRDs + Traefik v3, or NGINX Ingress Controller
- **Longhorn** — Distributed block storage with dynamic replica count, RWO and RWX StorageClasses
- **Cluster Autoscaler** — Multi-pool autoscaling via `HCLOUD_CLUSTER_CONFIG`
- **Flux CD** — GitOps bootstrap with automatic GitHub deploy key registration
- **Argo CD + Argo Rollouts** — UI-driven GitOps controller with Dex SSO and progressive delivery support
- **kube-prometheus-stack** — Prometheus, Alertmanager, and Grafana monitoring
- **Tailscale** — Kubernetes operator for in-cluster service exposure + node-level VPN mesh enrollment
- **Two-phase apply** — Clean separation of infrastructure provisioning and add-on deployment
- **Security-first defaults** — SSH blocked, NodePort blocked, etcd encrypted at rest, metadata API blocked

---

## Prerequisites

- **Hetzner Cloud** account with an API token (Read & Write)
- **SSH key** uploaded to the Hetzner Cloud project (name or ID)
- **Terraform >= 1.5** — [install guide](https://developer.hashicorp.com/terraform/install)
- **Helm CLI >= 3.14** (optional, for debugging Helm releases outside Terraform)
- For Flux: a GitHub personal access token with `repo` scope and a target repository
- For External-DNS / cert-manager: a Cloudflare API token with `Zone:DNS:Edit` permission
- For Argo CD GitHub SSO: a GitHub OAuth App (`clientID` + `clientSecret`) — see [Argo CD SSO](#argo-cd-sso)

---

## Quick Start

```hcl
module "cluster" {
  source  = "sarverenterprises/rke2-cluster/hcloud"
  version = "~> 0.2"

  cluster_name    = "my-cluster"
  hcloud_token    = var.hcloud_token
  ssh_keys        = [var.ssh_key_name]
  ssh_private_key = var.ssh_private_key

  node_pools = [
    {
      name        = "workers"
      server_type = "cpx21"
      node_count  = 1
    }
  ]
}
```

Apply in two phases:

```bash
# Phase 1: Provision infrastructure and wait for cluster readiness
terraform apply -target=module.cluster.null_resource.wait_for_cluster

# Phase 2: Deploy add-ons (Helm releases, Kubernetes resources)
terraform apply
```

After apply, export the kubeconfig:

```bash
terraform output -raw kubeconfig > ~/.kube/my-cluster.yaml
export KUBECONFIG=~/.kube/my-cluster.yaml
kubectl get nodes
```

---

## Examples

| Example | Description |
|---------|-------------|
| [`examples/minimal/`](examples/minimal/) | 3 CP + 1 worker pool, no add-ons — fewest required variables |
| [`examples/full/`](examples/full/) | All major add-ons enabled — shows Helm/Kubernetes provider wiring |
| [`examples/argocd/`](examples/argocd/) | Argo CD + Rollouts with optional GitHub SSO and Traefik ingress |

---

## Module Inputs

### Required

| Name | Type | Description |
|------|------|-------------|
| `cluster_name` | `string` | Unique cluster name. Used as prefix for all Hetzner resources. |
| `hcloud_token` | `string` | Hetzner Cloud API token (sensitive). |
| `ssh_keys` | `list(string)` | Hetzner SSH key names or IDs to add to all nodes. |
| `ssh_private_key` | `string` | SSH private key contents for provisioning (sensitive). |

### Cluster

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `location` | `string` | `"ash"` | Default Hetzner location (`ash`, `nbg1`, `fsn1`, `hel1`). |
| `control_plane_server_type` | `string` | `"cpx31"` | Server type for control plane nodes. |
| `node_pools` | `list(object)` | `[]` | Worker node pool definitions (see [Node Pools](#node-pool-object-schema)). |
| `rke2_version` | `string` | `"v1.32.13+rke2r1"` | RKE2 version to install on all nodes. |
| `network_cidr` | `string` | `"10.0.0.0/8"` | CIDR for the Hetzner private network. |
| `cluster_subnet_cidr` | `string` | `"10.11.0.0/16"` | CIDR for the cluster subnet (must be within `network_cidr`). |

### Security

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `trusted_ssh_cidrs` | `list(string)` | `[]` | CIDRs allowed to SSH. Default blocks all external SSH. |
| `kube_api_allowed_cidrs` | `list(string)` | `["0.0.0.0/0", "::/0"]` | CIDRs allowed to reach the Kubernetes API (port 6443). |
| `nodeport_allowed_cidrs` | `list(string)` | `[]` | CIDRs allowed to reach NodePort services. Default blocks all. |
| `expose_rke2_token` | `bool` | `false` | Output the RKE2 join token. Always stored in state regardless. |

### Add-on Feature Flags

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `enable_hcloud_ccm` | `bool` | `true` | Deploy Hetzner Cloud Controller Manager. |
| `enable_hcloud_csi` | `bool` | `true` | Deploy Hetzner CSI driver. |
| `enable_external_dns` | `bool` | `false` | Deploy External-DNS with Cloudflare. |
| `enable_cert_manager` | `bool` | `false` | Deploy cert-manager with Cloudflare DNS-01 issuer. |
| `enable_ingress` | `bool` | `false` | Deploy ingress controller. |
| `ingress_type` | `string` | `"traefik"` | Ingress controller: `traefik` or `nginx`. |
| `enable_longhorn` | `bool` | `false` | Deploy Longhorn distributed storage. |
| `enable_cluster_autoscaler` | `bool` | `false` | Deploy Cluster Autoscaler. |
| `enable_flux` | `bool` | `false` | Bootstrap Flux CD. |
| `enable_argocd` | `bool` | `false` | Deploy Argo CD and Argo Rollouts. |
| `enable_monitoring` | `bool` | `false` | Deploy kube-prometheus-stack. |
| `enable_tailscale_operator` | `bool` | `false` | Deploy Tailscale Kubernetes operator. |
| `enable_tailscale_nodes` | `bool` | `false` | Enroll nodes into Tailscale via cloud-init. |

### Cloudflare

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `cloudflare_api_token` | `string` | `null` | Cloudflare API token (required for External-DNS / cert-manager). |
| `cloudflare_zone_id` | `string` | `null` | Cloudflare Zone ID. |
| `cloudflare_zone` | `string` | `null` | Cloudflare zone domain (e.g. `example.com`). |

### Flux CD

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `github_token` | `string` | `null` | GitHub PAT with `repo` scope for Flux deploy key registration (sensitive). |
| `flux_github_org` | `string` | `null` | GitHub org or user owning the Flux repository. |
| `flux_github_repo` | `string` | `null` | GitHub repository name for Flux. |
| `flux_branch` | `string` | `"main"` | Git branch for Flux to track. |
| `flux_path` | `string` | `"clusters/main"` | Path within the Flux repository for cluster manifests. |
| `flux_deploy_key_mode` | `string` | `"auto"` | Deploy key mode: `auto` registers via GitHub API; `manual` skips registration. |

### Argo CD

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `argocd_hostname` | `string` | `null` | Hostname for Argo CD ingress (e.g. `argocd.example.com`). Requires `enable_ingress = true`. When `null`, no Ingress is created — access via `kubectl port-forward`. |
| `argocd_github_client_id` | `string` | `null` | GitHub OAuth App client ID for Dex SSO (sensitive). |
| `argocd_github_client_secret` | `string` | `null` | GitHub OAuth App client secret for Dex SSO (sensitive). |
| `argocd_dex_connectors` | `string` | `null` | Raw Dex connectors YAML. When set, overrides the GitHub auto-wire connector — use for Google, LDAP, OIDC, or any other Dex provider. |

### Monitoring

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `grafana_hostname` | `string` | `null` | Hostname for Grafana ingress (e.g. `grafana.example.com`). |

### Tailscale

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `tailscale_operator_auth_key` | `string` | `null` | Tailscale auth key for the Kubernetes operator (sensitive). |
| `tailscale_node_auth_key` | `string` | `null` | Tailscale auth key for node enrollment via cloud-init (sensitive). |

### Chart Version Pins

All chart versions use pessimistic constraint operators (`~>`) so patch-level updates are applied automatically while major/minor versions stay pinned.

| Name | Default | Description |
|------|---------|-------------|
| `cilium_chart_version` | `"~> 1.19.0"` | Cilium Helm chart version. |
| `hcloud_ccm_chart_version` | `"~> 1.21"` | Hetzner CCM Helm chart version. |
| `hcloud_csi_chart_version` | `"~> 2.9"` | Hetzner CSI Helm chart version. |
| `longhorn_chart_version` | `"~> 1.7"` | Longhorn Helm chart version. |
| `cert_manager_chart_version` | `"~> 1.16"` | cert-manager Helm chart version. |
| `external_dns_chart_version` | `"~> 1.14"` | External-DNS Helm chart version. |
| `traefik_chart_version` | `"~> 32.0"` | Traefik Helm chart version. |
| `flux_version` | `"~> 2.4"` | Flux CD chart version. |
| `cluster_autoscaler_chart_version` | `"9.46.6"` | Cluster Autoscaler Helm chart version. |
| `argocd_chart_version` | `"~> 9.4"` | Argo CD Helm chart version. |
| `argo_rollouts_chart_version` | `"~> 2.40"` | Argo Rollouts Helm chart version. |

### Node Pool Object Schema

```hcl
{
  name                 = string           # Required
  server_type          = string           # Required (e.g. "cpx21")
  node_count           = optional(number, 1)
  location             = optional(string)
  labels               = optional(map(string), {})
  taints               = optional(list(object({ key, value, effect })), [])
  scaling_mode         = optional(string, "fixed")  # "fixed" | "autoscaled"
  min_nodes            = optional(number, 1)
  max_nodes            = optional(number, 10)
  assign_public_ip     = optional(bool, false)
  longhorn_volume_size = optional(number, 0)        # GB; 0 = use OS disk
}
```

---

## Module Outputs

| Name | Sensitive | Description |
|------|-----------|-------------|
| `cluster_name` | No | Name of the provisioned cluster. |
| `control_plane_lb_ip` | No | Public IPv4 of the control plane load balancer. |
| `first_cp_public_ip` | No | Public IPv4 of the first control plane node. |
| `private_network_id` | No | ID of the Hetzner private network. |
| `node_pool_names` | No | Names of all worker node pools. |
| `kubeconfig` | Yes | Full kubeconfig file contents. Available after apply completes. |
| `rke2_token` | Yes | RKE2 join token. Only populated when `expose_rke2_token=true`. |
| `flux_public_key` | No | Flux SSH deploy key. Register as a GitHub deploy key when `flux_deploy_key_mode = "manual"`. |
| `argocd_admin_password_hint` | No | kubectl command to retrieve the initial Argo CD admin password. |

---

## Architecture

### Two-Phase Apply

The module uses a two-phase apply pattern to handle the bootstrapping dependency between infrastructure and add-ons:

1. **Phase 1** provisions all Hetzner Cloud resources (network, servers, load balancer, firewall) and installs RKE2 on control plane and worker nodes via cloud-init. A `null_resource.wait_for_cluster` resource SSH-polls the first control plane node until the API server is ready, then copies the kubeconfig to `.kube/<cluster_name>.yaml` on disk.

2. **Phase 2** deploys all Kubernetes add-ons via the Helm and Kubernetes Terraform providers, which read the kubeconfig written in Phase 1.

This separation ensures that provider configuration (which resolves at plan time) is not blocked by a kubeconfig that does not exist yet.

### Static First Control Plane IP

The first control plane node is assigned a static private IP (`cidrhost(cluster_subnet_cidr, 10)`). This address is embedded in every worker cloud-init template at plan time, eliminating a circular dependency where worker nodes would otherwise need to wait for the first control plane node's IP to be assigned before their cloud-init could be rendered.

### Hetzner Private Networking

All cluster traffic travels over a Hetzner private network and subnet. Each node receives a private IP in `cluster_subnet_cidr`. The control plane load balancer forwards TCP 6443 to all three control plane nodes, providing HA API access. Public IPs on worker nodes are optional (`assign_public_ip = false` by default).

### Cloud-Init Bootstrap

RKE2 is installed entirely via cloud-init on first boot. The control plane cloud-init template configures:

- `secrets-encryption: true` for etcd encryption at rest
- Static cluster token generated by Terraform
- Cilium CNI with `routingMode: tunnel` + `tunnelProtocol: vxlan` and MTU 1400
- Tailscale node enrollment (when `enable_tailscale_nodes = true`)

Worker nodes are bootstrapped with the first control plane node's private IP as the join server. Autoscaled pools embed the same cloud-init so that nodes added by the Cluster Autoscaler join the cluster correctly.

---

## Golden Snapshots (Optional)

By default, every node downloads and installs RKE2 from the internet at first boot (with retry logic). For faster boot times and reduced internet dependency, you can pre-bake a Hetzner Cloud snapshot with RKE2 already installed.

### Building a Snapshot

1. Create a Hetzner server with the target OS image (e.g. `ubuntu-24.04`).
2. Install RKE2 (do **not** start the service):
   ```bash
   curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=v1.32.13+rke2r1 sh -
   ```
3. Clean up cloud-init state and shut down the server.
4. Create a snapshot via the Hetzner Cloud Console, API, or `hcloud server create-image`.

> **Tip:** [Packer](https://www.packer.io/) with the `hcloud` builder can automate steps 1-4 into a repeatable pipeline.

### Using the Snapshot

Set `os_image` to the numeric snapshot ID instead of an OS name:

```hcl
os_image = "12345678"
```

### Trade-offs

| | Internet install (default) | Golden snapshot |
|---|---|---|
| Boot time | Slower (~30-90 s for download + install) | Faster (RKE2 already on disk) |
| Internet dependency | Required at first boot | Not required |
| RKE2 upgrades | Change `rke2_version` variable | Rebuild snapshot, then update `os_image` |
| Maintenance | None | Snapshot rebuild per RKE2 version |

---

## Add-on Usage

### Argo CD + Argo Rollouts

Enable Argo CD (and Argo Rollouts, which is always bundled) with `enable_argocd = true`. Argo CD and Flux CD are fully independent — either, both, or neither may be enabled on the same cluster.

```hcl
module "cluster" {
  source  = "sarverenterprises/rke2-cluster/hcloud"
  version = "~> 0.2"

  # ...

  enable_argocd = true
}
```

After apply, access the Argo CD UI via port-forward and retrieve the initial admin password:

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443

# In a separate terminal:
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

#### Argo CD with Traefik Ingress

Expose the Argo CD UI at a public hostname when `enable_ingress = true`:

```hcl
enable_ingress  = true
enable_argocd   = true
argocd_hostname = "argocd.example.com"

# Optional: automatic TLS via cert-manager
enable_cert_manager  = true
cloudflare_api_token = var.cloudflare_api_token
cloudflare_zone_id   = var.cloudflare_zone_id
cloudflare_zone      = "example.com"
```

#### Argo CD SSO

GitHub OAuth is the fastest path to SSO. Create a [GitHub OAuth App](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/creating-an-oauth-app) with the callback URL set to `https://<argocd_hostname>/api/dex/callback`, then pass the credentials:

```hcl
argocd_github_client_id     = var.argocd_github_client_id
argocd_github_client_secret = var.argocd_github_client_secret
```

For other providers (Google, LDAP, OIDC, Azure AD), pass a raw [Dex connectors](https://dexidp.io/docs/connectors/) YAML string via `argocd_dex_connectors`. This overrides the GitHub auto-wire entirely:

```hcl
argocd_dex_connectors = <<-EOT
  connectors:
  - type: oidc
    id: google
    name: Google
    config:
      issuer: https://accounts.google.com
      clientID: your-client-id
      clientSecret: your-client-secret
EOT
```

### Flux CD

```hcl
enable_flux      = true
github_token     = var.github_token
flux_github_org  = "my-org"
flux_github_repo = "my-gitops-repo"
```

Flux CD and Argo CD may both be enabled simultaneously. A common pattern is Flux managing cluster infrastructure (namespaces, operators, CRDs) while Argo CD manages application deployments.

### Cluster Autoscaler

Mark a pool `scaling_mode = "autoscaled"` and enable the autoscaler:

```hcl
node_pools = [
  {
    name         = "workers"
    server_type  = "cpx21"
    scaling_mode = "autoscaled"
    min_nodes    = 0
    max_nodes    = 5
  }
]

enable_cluster_autoscaler = true
```

---

## Security

### SSH Access

`trusted_ssh_cidrs` defaults to `[]`, which means port 22 is blocked on the Hetzner firewall for all external IPs. To enable SSH access only over Tailscale:

```hcl
trusted_ssh_cidrs = ["100.64.0.0/10"]  # Tailscale CGNAT range
```

### NodePort Access

`nodeport_allowed_cidrs` defaults to `[]`, blocking TCP 30000–32767 on all nodes. Use the Hetzner Load Balancer via CCM annotations instead of NodePort services.

### Kubernetes API Access

`kube_api_allowed_cidrs` defaults to open (`0.0.0.0/0`, `::/0`). Restrict this in production:

```hcl
kube_api_allowed_cidrs = ["100.64.0.0/10"]  # Tailscale only
```

### RKE2 Token Protection

The cluster join token is generated by `random_password.rke2_token` with `lifecycle { prevent_destroy = true }` to prevent accidental deletion. It is always stored in Terraform state (ensure your state backend uses encryption) and is not exposed as an output unless `expose_rke2_token = true`.

### etcd Encryption at Rest

All RKE2 clusters provisioned by this module have `secrets-encryption: true` set in the RKE2 server configuration, enabling etcd encryption at rest for Kubernetes Secret objects.

### Hetzner Metadata API

The Hetzner metadata API endpoint (`169.254.169.254`) is blocked from pod-level access via a `CiliumNetworkPolicy` applied post-bootstrap. This prevents workloads from reading instance metadata (including cloud-init user data, which contains the RKE2 join token).

---

## License

[MIT](LICENSE)
