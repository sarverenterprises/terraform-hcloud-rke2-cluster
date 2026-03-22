# Argo CD + Argo Rollouts example
#
# Demonstrates three Argo CD configurations:
#   A. Basic install (no SSO, no ingress) — access via kubectl port-forward
#   B. With Traefik ingress + cert-manager TLS (uncomment argocd_hostname block)
#   C. With GitHub SSO (uncomment argocd_github_* block)
#
# Two-phase apply pattern:
#   Phase 1: terraform apply -target=module.cluster.null_resource.wait_for_cluster
#   Phase 2: terraform apply
#
# After apply, retrieve the initial admin password:
#   kubectl -n argocd get secret argocd-initial-admin-secret \
#     -o jsonpath='{.data.password}' | base64 -d

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

# The Helm and Kubernetes providers read the kubeconfig written by the cluster
# module after Phase 1 completes. On the very first apply the file does not yet
# exist, so provider configuration is deferred until Phase 2.
provider "helm" {
  kubernetes = {
    config_path = module.cluster.kubeconfig != null ? "${path.root}/../../.kube/${var.cluster_name}.yaml" : ""
  }
}

provider "kubernetes" {
  config_path = module.cluster.kubeconfig != null ? "${path.root}/../../.kube/${var.cluster_name}.yaml" : ""
}

module "cluster" {
  source = "../../"

  cluster_name    = var.cluster_name
  hcloud_token    = var.hcloud_token
  ssh_keys        = [var.ssh_key_name]
  ssh_private_key = var.ssh_private_key
  location        = "ash"

  node_pools = [
    {
      name        = "workers"
      server_type = "cpx31"
      node_count  = 2
    }
  ]

  # --- Configuration A: Basic install (no SSO, no ingress) -----------------
  # Access the UI via: kubectl port-forward svc/argocd-server -n argocd 8080:443
  enable_argocd = true

  # --- Configuration B: Traefik ingress + TLS (requires Cloudflare vars) ---
  # Uncomment to expose the UI at https://<argocd_hostname>
  #
  # enable_ingress       = true
  # enable_cert_manager  = true
  # enable_external_dns  = true
  # cloudflare_api_token = var.cloudflare_api_token
  # cloudflare_zone_id   = var.cloudflare_zone_id
  # cloudflare_zone      = var.cloudflare_zone
  # argocd_hostname      = "argocd.${var.cloudflare_zone}"

  # --- Configuration C: GitHub SSO -----------------------------------------
  # Requires a GitHub OAuth App with callback URL:
  #   https://<argocd_hostname>/api/dex/callback
  # Create one at: https://github.com/settings/developers
  #
  # argocd_github_client_id     = var.argocd_github_client_id
  # argocd_github_client_secret = var.argocd_github_client_secret
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "cluster_name" {
  description = "Name for the cluster. Used as a prefix for all Hetzner resources."
  type        = string
  default     = "argocd-demo"
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

# Uncomment when using Configuration B (ingress + cert-manager)
#
# variable "cloudflare_api_token" {
#   description = "Cloudflare API token with Zone:DNS:Edit permission."
#   type        = string
#   sensitive   = true
# }
#
# variable "cloudflare_zone_id" {
#   description = "Cloudflare Zone ID."
#   type        = string
# }
#
# variable "cloudflare_zone" {
#   description = "Cloudflare zone domain (e.g., example.com)."
#   type        = string
# }

# Uncomment when using Configuration C (GitHub SSO)
#
# variable "argocd_github_client_id" {
#   description = "GitHub OAuth App client ID for Argo CD Dex SSO."
#   type        = string
#   sensitive   = true
# }
#
# variable "argocd_github_client_secret" {
#   description = "GitHub OAuth App client secret for Argo CD Dex SSO."
#   type        = string
#   sensitive   = true
# }

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "kubeconfig" {
  description = "Kubeconfig for connecting to the cluster."
  value       = module.cluster.kubeconfig
  sensitive   = true
}

output "control_plane_lb_ip" {
  description = "Public IP of the control plane load balancer."
  value       = module.cluster.control_plane_lb_ip
}

output "argocd_admin_password_hint" {
  description = "kubectl command to retrieve the Argo CD initial admin password."
  value       = module.cluster.argocd_admin_password_hint
}
