output "server_ids" {
  description = "List of Hetzner server IDs in this pool."
  value       = hcloud_server.nodes[*].id
}

output "server_names" {
  description = "List of server names in this pool."
  value       = hcloud_server.nodes[*].name
}

output "private_ips" {
  description = "Private network IP addresses of all nodes in this pool."
  value       = hcloud_server_network.nodes[*].ip
}

output "public_ips" {
  description = "Public IPv4 addresses of nodes. Empty string for nodes without a public IP."
  value = [
    for s in hcloud_server.nodes : coalesce(s.ipv4_address, "")
  ]
}

output "first_node_public_ip" {
  description = "Public IPv4 of the first node in this pool. Used for initial SSH access to fetch kubeconfig."
  value       = length(hcloud_server.nodes) > 0 ? hcloud_server.nodes[0].ipv4_address : null
}

output "first_node_id" {
  description = "Hetzner server ID of the first node."
  value       = length(hcloud_server.nodes) > 0 ? hcloud_server.nodes[0].id : null
}

output "volume_attachment_ids" {
  description = "IDs of Longhorn volume attachments. Empty if longhorn_volume_size=0."
  value       = hcloud_volume_attachment.longhorn_data[*].id
}
