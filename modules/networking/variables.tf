variable "cluster_name" {
  description = "Cluster name prefix for all networking resources."
  type        = string
}

variable "location" {
  description = "Primary Hetzner datacenter location for the load balancer and placement group."
  type        = string
}

variable "network_cidr" {
  description = "CIDR for the Hetzner private network."
  type        = string
}

variable "cluster_subnet_cidr" {
  description = "CIDR for the cluster subnet within the private network."
  type        = string
}

variable "enable_firewall" {
  description = "Create a Hetzner Firewall for the cluster."
  type        = bool
  default     = true
}

variable "trusted_ssh_cidrs" {
  description = "CIDRs allowed to SSH (TCP 22). Empty = SSH blocked."
  type        = list(string)
  default     = []
}

variable "kube_api_allowed_cidrs" {
  description = "CIDRs allowed to reach the Kubernetes API server (port 6443)."
  type        = list(string)
  default     = ["0.0.0.0/0", "::/0"]
}

variable "nodeport_allowed_cidrs" {
  description = "CIDRs allowed to reach NodePort services (TCP 30000-32767). Empty = closed."
  type        = list(string)
  default     = []
}

variable "existing_network_id" {
  description = "ID of an existing Hetzner network to attach this cluster to. When set, no new network is created — only a subnet is added. Set to null (default) to create a fresh network."
  type        = string
  default     = null
}
