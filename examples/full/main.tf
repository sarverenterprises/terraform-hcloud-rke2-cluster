terraform {
  required_version = ">= 1.5"
  required_providers {
    hcloud     = { source = "hetznercloud/hcloud", version = ">= 1.58.0" }
    helm       = { source = "hashicorp/helm", version = ">= 2.14.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = ">= 2.31.0" }
    tls        = { source = "hashicorp/tls", version = ">= 4.0.0" }
    null       = { source = "hashicorp/null", version = ">= 3.2.0" }
    random     = { source = "hashicorp/random", version = ">= 3.6.0" }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

# The Helm and Kubernetes providers read the kubeconfig file that the cluster
# module writes to .kube/<cluster_name>.yaml after a successful apply.
# On the very first apply the file does not yet exist, so provider configuration
# is deferred until Phase 2 (see two-phase apply note below).
provider "helm" {
  kubernetes = {
    config_path = module.cluster.kubeconfig != null ? "${path.root}/../../.kube/${var.cluster_name}.yaml" : ""
  }
}

provider "kubernetes" {
  config_path = module.cluster.kubeconfig != null ? "${path.root}/../../.kube/${var.cluster_name}.yaml" : ""
}

# Two-phase apply pattern
# -------------------------
# On the first run the kubeconfig file does not exist yet, so the Helm and
# Kubernetes providers cannot connect.  Apply in two phases:
#
#   Phase 1 — provision infrastructure and wait for cluster readiness:
#     terraform apply -target=module.cluster.null_resource.wait_for_cluster
#
#   Phase 2 — deploy all add-ons (Helm releases, Kubernetes resources):
#     terraform apply

module "cluster" {
  source = "../../"

  cluster_name    = var.cluster_name
  hcloud_token    = var.hcloud_token
  ssh_keys        = [var.ssh_key_name]
  ssh_private_key = var.ssh_private_key
  location        = "ash"

  node_pools = [
    {
      name        = "general"
      server_type = "cpx31"
      node_count  = 2
      labels      = { "workload-type" = "general" }
    },
    {
      name         = "autoscaled"
      server_type  = "cpx21"
      scaling_mode = "autoscaled"
      min_nodes    = 0
      max_nodes    = 5
    }
  ]

  # Security — restrict SSH and API to Tailscale CGNAT range
  trusted_ssh_cidrs      = ["100.64.0.0/10"]
  kube_api_allowed_cidrs = ["100.64.0.0/10"]

  # Core add-ons (on by default; listed explicitly for clarity)
  enable_hcloud_ccm = true
  enable_hcloud_csi = true

  # Networking add-ons
  enable_external_dns  = true
  cloudflare_api_token = var.cloudflare_api_token
  cloudflare_zone_id   = var.cloudflare_zone_id
  cloudflare_zone      = var.cloudflare_zone

  enable_cert_manager = true
  enable_ingress      = true
  ingress_type        = "traefik"

  # Storage
  enable_longhorn = true

  # Autoscaler — manages the "autoscaled" pool defined above
  enable_cluster_autoscaler = true

  # GitOps
  enable_flux      = true
  github_token     = var.github_token
  flux_github_org  = var.flux_github_org
  flux_github_repo = var.flux_github_repo

  # Monitoring
  enable_monitoring = true
  grafana_hostname  = "grafana.${var.cloudflare_zone}"

  # Tailscale
  enable_tailscale_operator   = true
  enable_tailscale_nodes      = true
  tailscale_node_auth_key     = var.tailscale_node_auth_key
  tailscale_operator_auth_key = var.tailscale_operator_auth_key
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name for the cluster. Used as a prefix for all Hetzner resources."
  type        = string
  default     = "prod"
}

variable "hcloud_token" {
  description = "Hetzner Cloud API token."
  type        = string
  sensitive   = true
}

variable "ssh_key_name" {
  description = "Name of an existing SSH key in the Hetzner Cloud project."
  type        = string
}

variable "ssh_private_key" {
  description = "Contents of the SSH private key used to provision nodes."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:DNS:Edit permission."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for DNS management."
  type        = string
}

variable "cloudflare_zone" {
  description = "Cloudflare zone domain (e.g., example.com)."
  type        = string
}

variable "github_token" {
  description = "GitHub personal access token with repo scope for Flux bootstrap."
  type        = string
  sensitive   = true
}

variable "flux_github_org" {
  description = "GitHub organization or user that owns the Flux repository."
  type        = string
}

variable "flux_github_repo" {
  description = "GitHub repository name for Flux to manage."
  type        = string
}

variable "tailscale_node_auth_key" {
  description = "Tailscale auth key for node-level enrollment (tag: tag:k8s-node)."
  type        = string
  sensitive   = true
}

variable "tailscale_operator_auth_key" {
  description = "Tailscale auth key for the Kubernetes operator (tag: tag:k8s-operator)."
  type        = string
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "kubeconfig" {
  description = "Kubeconfig file contents. Write to disk with: terraform output -raw kubeconfig > kubeconfig.yaml"
  value       = module.cluster.kubeconfig
  sensitive   = true
}

output "control_plane_lb_ip" {
  description = "Public IP of the control plane load balancer."
  value       = module.cluster.control_plane_lb_ip
}

output "flux_public_key" {
  description = "Public SSH key registered as a GitHub deploy key for Flux. Only set when enable_flux=true and flux_deploy_key_mode='auto'."
  value       = try(module.cluster.flux_public_key, null)
}
