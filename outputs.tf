output "cluster_name" {
  description = "Name of the provisioned cluster."
  value       = var.cluster_name
}

output "control_plane_lb_ip" {
  description = "Public IPv4 address of the control plane load balancer. Use this as the kubeconfig server address."
  value       = module.networking.control_plane_lb_ip
}

output "private_network_id" {
  description = "ID of the Hetzner private network created for the cluster."
  value       = module.networking.network_id
}

output "node_pool_names" {
  description = "Names of all worker node pools."
  value       = [for p in var.node_pools : p.name]
}

output "kubeconfig" {
  description = <<-EOT
    Kubeconfig file contents for connecting to the cluster.
    Available after `terraform apply` completes. Write to disk:
      terraform output -raw kubeconfig > kubeconfig.yaml
    IMPORTANT: The state backend must use encryption — this value is stored in plaintext in Terraform state.
  EOT
  value       = fileexists(local.kubeconfig_path) ? file(local.kubeconfig_path) : null
  sensitive   = true
}

output "rke2_token" {
  description = "RKE2 cluster join token. Only exposed when expose_rke2_token=true. Always stored in Terraform state regardless."
  value       = var.expose_rke2_token ? random_password.rke2_token.result : null
  sensitive   = true
}

output "first_cp_public_ip" {
  description = "Public IPv4 address of the first control plane node. Used for initial SSH access."
  value       = module.control_plane.first_node_public_ip
}
