variable "pool_name" {
  description = "Unique name prefix for servers in this pool."
  type        = string
}

variable "cluster_name" {
  description = "Cluster name — used for the 'cluster' server label so firewall label selectors match."
  type        = string
}

variable "role" {
  description = "RKE2 role: 'server' for control plane, 'agent' for workers."
  type        = string

  validation {
    condition     = contains(["server", "agent"], var.role)
    error_message = "role must be 'server' or 'agent'."
  }
}

variable "node_count" {
  description = "Number of nodes to provision. For autoscaled pools, this is the initial count (min_nodes)."
  type        = number
  default     = 1
}

variable "server_type" {
  description = "Hetzner server type (e.g., cpx31, cpx41)."
  type        = string
}

variable "location" {
  description = "Hetzner datacenter location."
  type        = string
}

variable "os_image" {
  description = "Hetzner OS image name (e.g., ubuntu-24.04)."
  type        = string
  default     = "ubuntu-24.04"
}

variable "ssh_keys" {
  description = "List of Hetzner SSH key names or IDs."
  type        = list(string)
}

variable "network_id" {
  description = "Hetzner private network ID to attach nodes to."
  type        = string
}

variable "subnet_id" {
  description = "Hetzner subnet ID within the private network."
  type        = string
}

variable "placement_group_id" {
  description = "Hetzner placement group ID. Null for worker pools."
  type        = string
  default     = null
}

variable "lb_id" {
  description = "Load balancer ID to register control plane nodes against. Null for worker pools."
  type        = string
  default     = null
}

variable "attach_to_lb" {
  description = "Whether to register nodes with the load balancer. Must be a static bool (not derived from lb_id) so count is known at plan time."
  type        = bool
  default     = false
}

variable "lb_network_attachment_id" {
  description = "ID of the LB-to-private-network attachment resource. Passed here to ensure the LB is on the private network before targets are registered."
  type        = string
  default     = null
}

variable "assign_public_ip" {
  description = "Assign a public IPv4 to each node. Default true for CP, false for workers."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels to apply to all nodes in this pool."
  type        = map(string)
  default     = {}
}

variable "taints" {
  description = "Kubernetes taints for nodes in this pool."
  type = list(object({
    key    = string
    value  = string
    effect = string
  }))
  default = []
}

variable "scaling_mode" {
  description = "'fixed' = Terraform-managed count; 'autoscaled' = CA manages after initial provisioning."
  type        = string
  default     = "fixed"
}

# =============================================================================
# Cloud-init / RKE2 configuration
# =============================================================================

variable "rke2_version" {
  description = "RKE2 release version to install."
  type        = string
}

variable "rke2_token" {
  description = "Shared cluster join token for all RKE2 nodes."
  type        = string
  sensitive   = true
}

variable "control_plane_lb_ip" {
  description = "Public IP of the control plane load balancer. Used in TLS SANs and agent join address."
  type        = string
}

variable "first_cp_ip" {
  description = "Static private IP of the first control plane node. Workers and follower CPs join via this address."
  type        = string
}

variable "cluster_subnet_cidr" {
  description = "Cluster subnet CIDR — used in cloud-init for node-ip detection."
  type        = string
}

variable "first_node_static_ip" {
  description = "Static private network IP to assign to the first node. Only used for role=server to give the first CP a known IP."
  type        = string
  default     = null
}

variable "pod_cidr" {
  description = "CIDR for Kubernetes pods. Passed to RKE2 cluster-cidr in control plane cloud-init."
  type        = string
  default     = "10.42.0.0/16"
}

variable "service_cidr" {
  description = "CIDR for Kubernetes services. Passed to RKE2 service-cidr in control plane cloud-init."
  type        = string
  default     = "10.43.0.0/16"
}

# =============================================================================
# Tailscale
# =============================================================================

variable "enable_tailscale_nodes" {
  description = "Install Tailscale on each node via cloud-init."
  type        = bool
  default     = false
}

variable "tailscale_auth_key" {
  description = "Tailscale auth key for node enrollment. Use ephemeral reusable keys."
  type        = string
  sensitive   = true
  default     = null
}

# =============================================================================
# etcd Backup
# =============================================================================

variable "enable_etcd_backup" {
  description = "Enable automated etcd snapshots to S3-compatible storage via RKE2 native config."
  type        = bool
  default     = false
}

variable "etcd_s3_endpoint" {
  description = "S3-compatible endpoint for etcd backups."
  type        = string
  default     = null
}

variable "etcd_s3_bucket" {
  description = "S3 bucket name for etcd snapshots."
  type        = string
  default     = null
}

variable "etcd_s3_access_key" {
  description = "S3 access key for etcd backup uploads."
  type        = string
  sensitive   = true
  default     = null
}

variable "etcd_s3_secret_key" {
  description = "S3 secret key for etcd backup uploads."
  type        = string
  sensitive   = true
  default     = null
}

variable "etcd_s3_region" {
  description = "S3 region for etcd backups."
  type        = string
  default     = null
}

variable "etcd_s3_folder" {
  description = "S3 folder (prefix) for etcd snapshots."
  type        = string
  default     = null
}

variable "etcd_snapshot_schedule_cron" {
  description = "Cron schedule for etcd snapshots."
  type        = string
  default     = "0 */6 * * *"
}

variable "etcd_snapshot_retention" {
  description = "Number of etcd snapshots to retain."
  type        = number
  default     = 48
}

# =============================================================================
# Longhorn data volume
# =============================================================================

variable "longhorn_volume_size" {
  description = "Size in GB of a dedicated Hetzner block volume for Longhorn data. 0 = use OS disk /var/lib/longhorn."
  type        = number
  default     = 0
}

