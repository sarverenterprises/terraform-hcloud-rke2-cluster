# terraform-hcloud-rke2-cluster

[![Terraform Registry](https://img.shields.io/badge/Terraform-Registry-7B42BC?logo=terraform)](https://registry.terraform.io)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)

A production-grade Terraform module that provisions fully functional [RKE2](https://docs.rke2.io/) Kubernetes clusters on [Hetzner Cloud](https://www.hetzner.com/cloud). The module mirrors the conventions of a production Hetzner + RKE2 setup and exposes all major add-ons through simple `enable_*` variables.

---

## Features

- **RKE2 HA control plane** — 3-node control plane with embedded etcd, fronted by a Hetzner Load Balancer
- **Hetzner CCM** — Cloud Controller Manager for automatic LoadBalancer provisioning
- **Hetzner CSI** — Container Storage Interface driver for block PersistentVolumes
- **Cilium CNI** — eBPF-based networking in VXLAN tunnel mode with MTU 1450 (optimised for Hetzner multi-NIC nodes)
- **External-DNS** — Dual Cloudflare deployments (proxied + DNS-only) for automatic DNS record management
- **cert-manager** — Automatic TLS certificates via Cloudflare DNS-01 ClusterIssuer
- **Traefik / NGINX ingress** — Gateway API CRDs + Traefik v3, or NGINX Ingress Controller
- **Longhorn** — Distributed block storage with dynamic replica count, RWO and RWX StorageClasses
- **Cluster Autoscaler** — Multi-pool autoscaling via `HCLOUD_CLUSTER_CONFIG`
- **Flux CD** — GitOps bootstrap with automatic GitHub deploy key registration
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

---

## Quick Start

```hcl
module "cluster" {
  source = "github.com/sarverenterprises/terraform-hcloud-rke2-cluster"

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

---

## Module Inputs

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `cluster_name` | `string` | — | Unique cluster name. Used as prefix for all Hetzner resources. |
| `hcloud_token` | `string` | — | Default Hetzner Cloud API token (sensitive). |
| `ssh_keys` | `list(string)` | — | Hetzner SSH key names or IDs to add to all nodes. |
| `ssh_private_key` | `string` | — | SSH private key contents for provisioning (sensitive). |
| `location` | `string` | `"ash"` | Default Hetzner location (`ash`, `nbg1`, `fsn1`, `hel1`). |
| `control_plane_server_type` | `string` | `"cpx31"` | Server type for control plane nodes. |
| `node_pools` | `list(object)` | `[]` | Worker node pool definitions (see Node Pools below). |
| `enable_hcloud_ccm` | `bool` | `true` | Deploy Hetzner Cloud Controller Manager. |
| `enable_hcloud_csi` | `bool` | `true` | Deploy Hetzner CSI driver. |
| `enable_external_dns` | `bool` | `false` | Deploy External-DNS with Cloudflare. |
| `enable_cert_manager` | `bool` | `false` | Deploy cert-manager with Cloudflare DNS-01 issuer. |
| `enable_ingress` | `bool` | `false` | Deploy ingress controller. |
| `ingress_type` | `string` | `"traefik"` | Ingress controller: `traefik` or `nginx`. |
| `enable_longhorn` | `bool` | `false` | Deploy Longhorn distributed storage. |
| `enable_cluster_autoscaler` | `bool` | `false` | Deploy Cluster Autoscaler. |
| `enable_flux` | `bool` | `false` | Bootstrap Flux CD. |
| `enable_monitoring` | `bool` | `false` | Deploy kube-prometheus-stack. |
| `enable_tailscale_operator` | `bool` | `false` | Deploy Tailscale Kubernetes operator. |
| `enable_tailscale_nodes` | `bool` | `false` | Enroll nodes into Tailscale via cloud-init. |
| `trusted_ssh_cidrs` | `list(string)` | `[]` | CIDRs allowed to SSH. Default blocks all external SSH. |
| `kube_api_allowed_cidrs` | `list(string)` | `["0.0.0.0/0", "::/0"]` | CIDRs allowed to reach the Kubernetes API (port 6443). |
| `cloudflare_api_token` | `string` | `null` | Cloudflare API token (required for External-DNS / cert-manager). |
| `cloudflare_zone_id` | `string` | `null` | Cloudflare Zone ID. |
| `cloudflare_zone` | `string` | `null` | Cloudflare zone domain (e.g. `example.com`). |
| `github_token` | `string` | `null` | GitHub token for Flux deploy key registration (sensitive). |
| `flux_github_org` | `string` | `null` | GitHub org or user owning the Flux repository. |
| `flux_github_repo` | `string` | `null` | GitHub repository name for Flux. |
| `tailscale_operator_auth_key` | `string` | `null` | Tailscale auth key for the operator (sensitive). |
| `tailscale_node_auth_key` | `string` | `null` | Tailscale auth key for node enrollment (sensitive). |
| `grafana_hostname` | `string` | `null` | Hostname for Grafana ingress (e.g. `grafana.example.com`). |
| `rke2_version` | `string` | `"v1.32.13+rke2r1"` | RKE2 version to install on all nodes. |
| `network_cidr` | `string` | `"10.0.0.0/8"` | CIDR for the Hetzner private network. |
| `cluster_subnet_cidr` | `string` | `"10.11.0.0/16"` | CIDR for the cluster subnet (must be within `network_cidr`). |
| `expose_rke2_token` | `bool` | `false` | Output the RKE2 join token. Always stored in state regardless. |

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
- Cilium CNI with `routingMode: tunnel` + `tunnelProtocol: vxlan` and MTU 1450
- Tailscale node enrollment (when `enable_tailscale_nodes = true`)

Worker nodes are bootstrapped with the first control plane node's private IP as the join server. Autoscaled pools embed the same cloud-init so that nodes added by the Cluster Autoscaler join the cluster correctly.

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

[Apache License 2.0](LICENSE)
