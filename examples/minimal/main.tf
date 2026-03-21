# Minimal example: 3 CP + 1 worker pool, no add-ons
# Demonstrates the two-phase apply pattern.
#
# Phase 1: terraform apply -target=module.cluster.null_resource.wait_for_cluster
# Phase 2: terraform apply

terraform {
  required_version = ">= 1.5"
  required_providers {
    hcloud = { source = "hetznercloud/hcloud", version = ">= 1.58.0" }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

module "cluster" {
  source = "../../"

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

variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "ssh_key_name" {
  type = string
}

variable "ssh_private_key" {
  type      = string
  sensitive = true
}

output "kubeconfig" {
  value     = module.cluster.kubeconfig
  sensitive = true
}

output "control_plane_lb_ip" {
  value = module.cluster.control_plane_lb_ip
}
