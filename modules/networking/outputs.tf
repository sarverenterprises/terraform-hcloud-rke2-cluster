output "network_id" {
  description = "ID of the Hetzner private network."
  value       = local.network_id
}

output "network_name" {
  description = "Name of the Hetzner private network."
  value       = local.network_name
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

output "private_lb_ip" {
  description = "Private IPv4 address of the control plane load balancer within the cluster subnet. Use for kubeconfig server URL and tls-san — avoids public internet exposure of the API server."
  value       = hcloud_load_balancer_network.control_plane.ip
}

output "lb_service_ids" {
  description = "IDs of the LB services (kube-api + rke2-supervisor). Referenced by wait_for_cluster to ensure services exist before health-checking the LB."
  value = [
    hcloud_load_balancer_service.kube_api.id,
    hcloud_load_balancer_service.rke2_supervisor.id,
  ]
}

output "firewall_id" {
  description = "ID of the cluster firewall. Null if enable_firewall=false."
  value       = var.enable_firewall ? hcloud_firewall.cluster[0].id : null
}
