# =============================================================================
# Cluster Identity
# =============================================================================

variable "cluster_name" {
  description = "Cluster name — used to namespace Helm releases and Kubernetes resources."
  type        = string
}

# =============================================================================
# Hetzner Tokens
# =============================================================================

variable "hcloud_ccm_token" {
  description = "Hetzner token for Cloud Controller Manager."
  type        = string
  sensitive   = true
}

variable "hcloud_csi_token" {
  description = "Hetzner token for CSI driver."
  type        = string
  sensitive   = true
}

variable "hcloud_autoscaler_token" {
  description = "Hetzner token for Cluster Autoscaler."
  type        = string
  sensitive   = true
}

# =============================================================================
# Network
# =============================================================================

variable "private_network_name" {
  description = "Name of the Hetzner private network. Used in CCM and autoscaler config."
  type        = string
}

variable "private_network_id" {
  description = "ID of the Hetzner private network."
  type        = string
}

variable "control_plane_lb_ip" {
  description = "Private IP of the control plane load balancer. Used in autoscaler cloud-init."
  type        = string
}

variable "cluster_subnet_cidr" {
  description = "Cluster subnet CIDR. Used in autoscaler cloud-init."
  type        = string
}

# =============================================================================
# RKE2 / OS
# =============================================================================

variable "rke2_version" {
  description = "RKE2 version to install on autoscaled nodes."
  type        = string
}

variable "rke2_cluster_token" {
  description = "RKE2 cluster join token. Injected into autoscaler node cloud-inits."
  type        = string
  sensitive   = true
}

variable "os_image" {
  description = "Hetzner OS image for autoscaled nodes."
  type        = string
}

# =============================================================================
# Worker Pools (for autoscaler HCLOUD_CLUSTER_CONFIG)
# =============================================================================

variable "autoscaler_pool_cloud_inits" {
  description = "Pre-rendered cloud-init strings for autoscaled pools, keyed by full pool name (e.g. 'mycluster-workers'). Rendered in the root module to avoid cross-module template path violations when sourced from a Git remote."
  type        = map(string)
  default     = {}
}

variable "node_pools" {
  description = "Worker node pool definitions. Used to build autoscaler HCLOUD_CLUSTER_CONFIG."
  type = list(object({
    name        = string
    server_type = string
    node_count  = optional(number, 1)
    location    = optional(string)

    labels = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])

    scaling_mode = optional(string, "fixed")
    min_nodes    = optional(number, 1)
    max_nodes    = optional(number, 10)

    assign_public_ip     = optional(bool, false)
    longhorn_volume_size = optional(number, 0)
  }))
  default = []
}

# =============================================================================
# Longhorn
# =============================================================================

variable "longhorn_default_replicas" {
  description = "Default Longhorn replica count. Computed from min(total_workers, 3)."
  type        = number
  default     = 3
}

variable "longhorn_rwx_mode" {
  description = "Longhorn RWX backend: 'builtin' or 'external'."
  type        = string
  default     = "builtin"
}

# =============================================================================
# Tailscale
# =============================================================================

variable "enable_tailscale_nodes" {
  description = "Whether Tailscale is installed on nodes. Used to inject auth key into autoscaler cloud-inits."
  type        = bool
  default     = false
}

variable "tailscale_node_auth_key" {
  description = "Tailscale auth key for node-level enrollment."
  type        = string
  sensitive   = true
  default     = null
}

variable "tailscale_operator_auth_key" {
  description = "Tailscale auth key for the Kubernetes operator."
  type        = string
  sensitive   = true
  default     = null
}

# =============================================================================
# Add-on Feature Flags
# =============================================================================

variable "enable_hcloud_ccm" {
  description = "Deploy Hetzner Cloud Controller Manager."
  type        = bool
  default     = true
}

variable "enable_hcloud_csi" {
  description = "Deploy Hetzner CSI driver."
  type        = bool
  default     = true
}

variable "enable_external_dns" {
  description = "Deploy External-DNS."
  type        = bool
  default     = false
}

variable "enable_cert_manager" {
  description = "Deploy cert-manager."
  type        = bool
  default     = false
}

variable "enable_ingress" {
  description = "Deploy ingress controller."
  type        = bool
  default     = false
}

variable "ingress_type" {
  description = "Ingress controller type: 'traefik' or 'nginx'."
  type        = string
  default     = "traefik"
}

variable "enable_longhorn" {
  description = "Deploy Longhorn."
  type        = bool
  default     = false
}

variable "enable_cluster_autoscaler" {
  description = "Deploy Cluster Autoscaler."
  type        = bool
  default     = false
}

variable "autoscaler_rbac_level" {
  description = "RBAC scope for the autoscaler: 'upstream' or 'minimal'."
  type        = string
  default     = "upstream"
}

variable "enable_flux" {
  description = "Bootstrap Flux CD."
  type        = bool
  default     = false
}

variable "flux_deploy_key_mode" {
  description = "Flux deploy key mode: 'auto' or 'manual'."
  type        = string
  default     = "auto"
}

variable "enable_monitoring" {
  description = "Deploy kube-prometheus-stack."
  type        = bool
  default     = false
}

variable "enable_tailscale_operator" {
  description = "Deploy Tailscale Kubernetes operator."
  type        = bool
  default     = false
}

# =============================================================================
# Cloudflare
# =============================================================================

variable "cloudflare_api_token" {
  description = "Cloudflare API token. Required when enable_external_dns or enable_cert_manager."
  type        = string
  sensitive   = true
  default     = null
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID."
  type        = string
  default     = null
}

variable "cloudflare_zone" {
  description = "Cloudflare zone domain (e.g., 'example.com')."
  type        = string
  default     = null
}

# =============================================================================
# GitHub / Flux
# =============================================================================

variable "github_token" {
  description = "GitHub PAT. Required when enable_flux=true."
  type        = string
  sensitive   = true
  default     = null
}

variable "flux_github_org" {
  description = "GitHub org or user for Flux repository."
  type        = string
  default     = null
}

variable "flux_github_repo" {
  description = "GitHub repository name for Flux."
  type        = string
  default     = null
}

variable "flux_branch" {
  description = "Git branch for Flux to track."
  type        = string
  default     = "main"
}

variable "flux_path" {
  description = "Path in the Flux repository for cluster manifests."
  type        = string
  default     = "clusters/main"
}

# =============================================================================
# Monitoring
# =============================================================================

variable "grafana_hostname" {
  description = "Hostname for Grafana ingress."
  type        = string
  default     = null
}

# =============================================================================
# Chart Versions
# =============================================================================

variable "cilium_chart_version" {
  description = "Cilium Helm chart version."
  type        = string
  default     = "~> 1.19.0"
}

variable "hcloud_ccm_chart_version" {
  description = "Hetzner CCM Helm chart version."
  type        = string
  default     = "~> 1.21"
}

variable "hcloud_csi_chart_version" {
  description = "Hetzner CSI Helm chart version."
  type        = string
  default     = "~> 2.9"
}

variable "longhorn_chart_version" {
  description = "Longhorn Helm chart version."
  type        = string
  default     = "~> 1.7"
}

variable "cert_manager_chart_version" {
  description = "cert-manager Helm chart version."
  type        = string
  default     = "~> 1.16"
}

variable "external_dns_chart_version" {
  description = "External-DNS Helm chart version."
  type        = string
  default     = "~> 1.14"
}

variable "traefik_chart_version" {
  description = "Traefik Helm chart version."
  type        = string
  default     = "~> 32.0"
}

variable "flux_version" {
  description = "Flux CD version."
  type        = string
  default     = "~> 2.4"
}

variable "cluster_autoscaler_chart_version" {
  description = "Cluster Autoscaler Helm chart version."
  type        = string
  default     = "9.46.6"
}

variable "cluster_autoscaler_image_tag" {
  description = "Cluster Autoscaler container image tag."
  type        = string
  default     = "v1.32.7"
}
