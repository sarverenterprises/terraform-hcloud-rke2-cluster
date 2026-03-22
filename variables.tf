# =============================================================================
# Cluster Identity
# =============================================================================

variable "cluster_name" {
  description = "Unique name for the cluster. Used as a prefix for all Hetzner resources."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric with hyphens, 3-32 chars, starting with a letter."
  }
}

variable "location" {
  description = "Default Hetzner Cloud datacenter location. Used for control plane and any worker pool that does not override location."
  type        = string
  default     = "ash"

  validation {
    condition     = contains(["ash", "nbg1", "fsn1", "hel1"], var.location)
    error_message = "location must be one of: ash, nbg1, fsn1, hel1."
  }
}

# =============================================================================
# Hetzner Cloud API Tokens
# Separate tokens enable least-privilege per component (future Hetzner RBAC).
# Callers may pass the same token for all three until Hetzner supports scoping.
# =============================================================================

variable "hcloud_token" {
  description = "Default Hetzner Cloud API token. Used by any component-specific token that is null. If null, the HCLOUD_TOKEN environment variable must be set for the hcloud provider."
  type        = string
  sensitive   = true
  default     = null
}

variable "hcloud_ccm_token" {
  description = "Hetzner token for Cloud Controller Manager. Defaults to hcloud_token if null."
  type        = string
  sensitive   = true
  default     = null
}

variable "hcloud_csi_token" {
  description = "Hetzner token for CSI driver. Defaults to hcloud_token if null."
  type        = string
  sensitive   = true
  default     = null
}

variable "hcloud_autoscaler_token" {
  description = "Hetzner token for Cluster Autoscaler. Defaults to hcloud_token if null."
  type        = string
  sensitive   = true
  default     = null
}

# =============================================================================
# OS & RKE2 Configuration
# =============================================================================

variable "os_image" {
  description = "Hetzner Cloud OS image for all nodes. Must be an Ubuntu LTS image."
  type        = string
  default     = "ubuntu-24.04"
}

variable "rke2_version" {
  description = "RKE2 release version to install on all nodes."
  type        = string
  default     = "v1.32.13+rke2r1"
}

variable "ssh_keys" {
  description = "List of Hetzner SSH key names or IDs to add to all nodes."
  type        = list(string)
}

variable "ssh_private_key" {
  description = "Contents of the SSH private key used to provision nodes. Required to fetch the kubeconfig after cluster creation."
  type        = string
  sensitive   = true
}

# =============================================================================
# Control Plane
# =============================================================================

variable "control_plane_server_type" {
  description = "Hetzner server type for control plane nodes. cpx31 is recommended (4 vCPU, 8 GB RAM)."
  type        = string
  default     = "cpx31"
}

variable "control_plane_location" {
  description = "Hetzner location for control plane nodes. Defaults to var.location if null."
  type        = string
  default     = null
}

# =============================================================================
# Networking
# =============================================================================

variable "network_cidr" {
  description = "CIDR for the Hetzner private network."
  type        = string
  default     = "10.0.0.0/8"
}

variable "cluster_subnet_cidr" {
  description = "CIDR for the cluster subnet within the private network. Must be within network_cidr."
  type        = string
  default     = "10.11.0.0/16"

  validation {
    condition     = tonumber(split("/", var.cluster_subnet_cidr)[1]) >= 16
    error_message = "cluster_subnet_cidr must be /16 or smaller to limit etcd firewall rule blast radius."
  }
}

# =============================================================================
# Worker Node Pools
# =============================================================================

variable "node_pools" {
  description = <<-EOT
    List of worker node pool configurations.
    Each pool is independently configurable for server type, count, location, labels, taints,
    autoscaling mode, public IP assignment, and optional dedicated Longhorn data volume.
  EOT
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

    # "fixed" = Terraform-managed count; "autoscaled" = Cluster Autoscaler manages after bootstrap
    scaling_mode = optional(string, "fixed")
    min_nodes    = optional(number, 1)
    max_nodes    = optional(number, 10)

    assign_public_ip = optional(bool, false)

    # Size in GB of a dedicated Hetzner block volume for Longhorn data.
    # 0 = Longhorn uses the OS disk's /var/lib/longhorn directory.
    longhorn_volume_size = optional(number, 0)
  }))
  default = []

  validation {
    condition = alltrue([
      for p in var.node_pools : contains(["fixed", "autoscaled"], p.scaling_mode)
    ])
    error_message = "Each node pool's scaling_mode must be 'fixed' or 'autoscaled'."
  }
}

# =============================================================================
# Security & Firewall
# =============================================================================

variable "enable_firewall" {
  description = "Create Hetzner Firewall with production-derived security rules."
  type        = bool
  default     = true
}

variable "trusted_ssh_cidrs" {
  description = <<-EOT
    CIDRs allowed to SSH (TCP 22) to all nodes.
    Default [] = SSH blocked from all external IPs.
    Use ["100.64.0.0/10"] if using Tailscale node-level access without public SSH.
  EOT
  type        = list(string)
  default     = []
}

variable "kube_api_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach the Kubernetes API server (port 6443) on the load balancer.
    Default open — restrict to office/VPN/Tailscale CIDRs in production.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "nodeport_allowed_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach NodePort services (TCP 30000-32767) on worker nodes.
    Default [] = NodePort closed. Prefer Hetzner LB via CCM instead of NodePort.
  EOT
  type        = list(string)
  default     = []
}

# =============================================================================
# Add-on Flags (all optional except CCM + CSI which default on)
# =============================================================================

variable "enable_hcloud_ccm" {
  description = "Deploy Hetzner Cloud Controller Manager (required for LB provisioning). Defaults on."
  type        = bool
  default     = true
}

variable "enable_hcloud_csi" {
  description = "Deploy Hetzner CSI driver (required for PersistentVolumes). Defaults on."
  type        = bool
  default     = true
}

variable "enable_external_dns" {
  description = "Deploy External-DNS with two Cloudflare deployments (proxied + DNS-only)."
  type        = bool
  default     = false
}

variable "enable_cert_manager" {
  description = "Deploy cert-manager with Cloudflare DNS-01 ClusterIssuer."
  type        = bool
  default     = false
}

variable "enable_ingress" {
  description = "Deploy ingress controller (Traefik + Gateway API or NGINX)."
  type        = bool
  default     = false
}

variable "ingress_type" {
  description = "Ingress controller to deploy. 'traefik' installs Traefik + Gateway API CRDs; 'nginx' installs NGINX Ingress Controller."
  type        = string
  default     = "traefik"

  validation {
    condition     = contains(["traefik", "nginx"], var.ingress_type)
    error_message = "ingress_type must be 'traefik' or 'nginx'."
  }
}

variable "enable_longhorn" {
  description = "Deploy Longhorn distributed storage with RWO and RWX StorageClasses."
  type        = bool
  default     = false
}

variable "longhorn_rwx_mode" {
  description = "Longhorn RWX backend. 'builtin' uses Longhorn's built-in share manager; 'external' deploys a separate NFS server."
  type        = string
  default     = "builtin"

  validation {
    condition     = contains(["builtin", "external"], var.longhorn_rwx_mode)
    error_message = "longhorn_rwx_mode must be 'builtin' or 'external'."
  }
}

variable "enable_cluster_autoscaler" {
  description = "Deploy Cluster Autoscaler for pools with scaling_mode='autoscaled'."
  type        = bool
  default     = false
}

variable "autoscaler_rbac_level" {
  description = "RBAC scope for the autoscaler ClusterRole. 'upstream' tracks the standard upstream ClusterRole; 'minimal' uses a reduced permission set."
  type        = string
  default     = "upstream"

  validation {
    condition     = contains(["upstream", "minimal"], var.autoscaler_rbac_level)
    error_message = "autoscaler_rbac_level must be 'upstream' or 'minimal'."
  }
}

variable "enable_flux" {
  description = "Bootstrap Flux CD via the fluxcd/flux Terraform provider."
  type        = bool
  default     = false
}

variable "flux_deploy_key_mode" {
  description = "Deploy key mode for Flux. 'auto' generates an SSH keypair and registers it via GitHub API; 'manual' uses a pre-registered key."
  type        = string
  default     = "auto"

  validation {
    condition     = contains(["auto", "manual"], var.flux_deploy_key_mode)
    error_message = "flux_deploy_key_mode must be 'auto' or 'manual'."
  }
}

variable "enable_monitoring" {
  description = "Deploy kube-prometheus-stack (Prometheus, Alertmanager, Grafana)."
  type        = bool
  default     = false
}

variable "enable_tailscale_operator" {
  description = "Deploy Tailscale Kubernetes operator."
  type        = bool
  default     = false
}

variable "enable_tailscale_nodes" {
  description = "Install Tailscale on each node via cloud-init for VPN mesh SSH access."
  type        = bool
  default     = false
}

# =============================================================================
# Cloudflare (required when enable_external_dns or enable_cert_manager = true)
# =============================================================================

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:DNS:Edit permission on cloudflare_zone_id. Required for External-DNS and cert-manager."
  type        = string
  sensitive   = true
  default     = null
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID. Required when enable_external_dns or enable_cert_manager is true."
  type        = string
  default     = null
}

variable "cloudflare_zone" {
  description = "Cloudflare zone domain (e.g., 'example.com'). Required for external-dns domainFilter."
  type        = string
  default     = null
}

# =============================================================================
# Flux / GitHub (required when enable_flux = true)
# =============================================================================

variable "github_token" {
  description = "GitHub personal access token with repo scope. Required when enable_flux=true and flux_deploy_key_mode='auto'."
  type        = string
  sensitive   = true
  default     = null
}

variable "flux_github_org" {
  description = "GitHub organization or user that owns the Flux repository."
  type        = string
  default     = null
}

variable "flux_github_repo" {
  description = "GitHub repository name for Flux to manage."
  type        = string
  default     = null
}

variable "flux_branch" {
  description = "Git branch for Flux to track."
  type        = string
  default     = "main"
}

variable "flux_path" {
  description = "Path within the Flux repository where cluster manifests live."
  type        = string
  default     = "clusters/main"
}

# =============================================================================
# Tailscale (required when enable_tailscale_operator or enable_tailscale_nodes = true)
# =============================================================================

variable "tailscale_operator_auth_key" {
  description = "Tailscale auth key for the Kubernetes operator. Separate from node-level key; use tag:k8s-operator ACL tag."
  type        = string
  sensitive   = true
  default     = null
}

variable "tailscale_node_auth_key" {
  description = "Tailscale auth key for node-level enrollment via cloud-init. Use ephemeral reusable keys; tag: tag:k8s-node."
  type        = string
  sensitive   = true
  default     = null
}

# =============================================================================
# Monitoring
# =============================================================================

variable "grafana_hostname" {
  description = "Hostname for Grafana ingress. Used by external-dns + cert-manager if both are enabled."
  type        = string
  default     = null
}

# =============================================================================
# Argo CD (required when enable_argocd = true)
# =============================================================================

variable "enable_argocd" {
  description = "Deploy Argo CD and Argo Rollouts."
  type        = bool
  default     = false
}

variable "argocd_hostname" {
  description = "Hostname for Argo CD ingress (e.g. 'argocd.example.com'). When null, no Ingress is created — access via kubectl port-forward. Requires enable_ingress = true when set."
  type        = string
  default     = null
}

variable "argocd_github_client_id" {
  description = "GitHub OAuth App client ID for Argo CD Dex SSO. Provide together with argocd_github_client_secret to enable GitHub login."
  type        = string
  sensitive   = true
  default     = null
}

variable "argocd_github_client_secret" {
  description = "GitHub OAuth App client secret for Argo CD Dex SSO."
  type        = string
  sensitive   = true
  default     = null
}

variable "argocd_dex_connectors" {
  description = "Raw Dex connectors YAML string. When set, overrides the auto-wired GitHub connector. Use for non-GitHub providers (Google, LDAP, OIDC, etc.)."
  type        = string
  default     = null
}

# =============================================================================
# Outputs
# =============================================================================

variable "expose_rke2_token" {
  description = "Output the RKE2 cluster join token. Default false — only enable if callers need it outside this module. The token is always stored in Terraform state."
  type        = bool
  default     = false
}

# =============================================================================
# Component Version Pins
# =============================================================================

variable "cilium_chart_version" {
  description = "Cilium Helm chart version. Must be an exact version — Helm provider v3 does not support constraint expressions."
  type        = string
  default     = "1.19.1"
}

variable "hcloud_ccm_chart_version" {
  description = "Hetzner Cloud Controller Manager Helm chart version. Must be an exact version — Helm provider v3 does not support constraint expressions."
  type        = string
  default     = "1.30.1"
}

variable "hcloud_csi_chart_version" {
  description = "Hetzner CSI driver Helm chart version. Must be an exact version — Helm provider v3 does not support constraint expressions."
  type        = string
  default     = "2.20.0"
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
  description = "Traefik Helm chart version (v3.x)."
  type        = string
  default     = "~> 32.0"
}

variable "flux_version" {
  description = "Flux CD version for flux_bootstrap_git."
  type        = string
  default     = "~> 2.4"
}

variable "cluster_autoscaler_chart_version" {
  description = "Cluster Autoscaler Helm chart version. Must match cluster Kubernetes minor version."
  type        = string
  default     = "9.46.6"
}

variable "cluster_autoscaler_image_tag" {
  description = "Cluster Autoscaler container image tag. Must match cluster Kubernetes minor version (e.g., v1.32.7 for K8s 1.32)."
  type        = string
  default     = "v1.32.7"
}

variable "argocd_chart_version" {
  description = "Argo CD Helm chart version."
  type        = string
  default     = "~> 9.4"
}

variable "argo_rollouts_chart_version" {
  description = "Argo Rollouts Helm chart version."
  type        = string
  default     = "~> 2.40"
}
