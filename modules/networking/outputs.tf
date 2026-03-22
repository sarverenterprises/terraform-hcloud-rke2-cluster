output "network_id" {
  description = "ID of the Hetzner private network."
  value       = hcloud_network.cluster.id
}

output "network_name" {
  description = "Name of the Hetzner private network."
  value       = hcloud_network.cluster.name
}

output "subnet_id" {
  description = "ID of the cluster subnet."
  value       = hcloud_network_subnet.cluster.id
}

output "placement_group_id" {
  description = "ID of the control plane spread placement group."
  value       = hcloud_placement_group.control_plane.id
}

output "lb_id" {
  description = "ID of the control plane load balancer."
  value       = hcloud_load_balancer.control_plane.id
}

output "lb_network_attachment_id" {
  description = "ID of the LB-to-private-network attachment. Used to order LB target registration after the LB joins the network."
  value       = hcloud_load_balancer_network.control_plane.id
}

output "control_plane_lb_ip" {
  description = "Public IPv4 address of the control plane load balancer."
  value       = hcloud_load_balancer.control_plane.ipv4
}

output "firewall_id" {
  description = "ID of the cluster firewall. Null if enable_firewall=false."
  value       = var.enable_firewall ? hcloud_firewall.cluster[0].id : null
}
