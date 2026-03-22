locals {
  # Taint string for RKE2 config (only set on worker pools)
  taint_args = join("\n", [
    for t in var.taints : "  - \"${t.key}=${t.value}:${t.effect}\""
  ])
  has_taints = length(var.taints) > 0

  # Label string for RKE2 config
  label_args = join("\n", [
    for k, v in var.labels : "  - \"${k}=${v}\""
  ])
  has_labels = length(var.labels) > 0
}

# =============================================================================
# Hetzner Servers
# =============================================================================

resource "hcloud_server" "nodes" {
  count = var.node_count

  name        = "${var.pool_name}-${count.index}"
  server_type = var.server_type
  image       = var.os_image
  location    = var.location
  ssh_keys    = var.ssh_keys

  # Assign to placement group (CP only — spread across physical hosts)
  placement_group_id = var.placement_group_id

  # Control public IPv4 assignment per pool
  public_net {
    ipv4_enabled = var.assign_public_ip
    ipv6_enabled = true
  }

  # Bootstrap via cloud-init
  user_data = (
    var.role == "server" && count.index == 0
    ? templatefile("${path.module}/templates/cp-init.yaml.tpl", {
      rke2_version         = var.rke2_version
      rke2_token           = var.rke2_token
      control_plane_lb_ip  = var.control_plane_lb_ip
      node_ip              = var.first_node_static_ip # static, known at plan time
      first_cp_ip          = null                     # unused for init node; required by template
      cluster_init         = true
      has_labels           = local.has_labels
      label_args           = local.label_args
      has_taints           = local.has_taints
      taint_args           = local.taint_args
      longhorn_volume_size = var.longhorn_volume_size
      enable_tailscale     = var.enable_tailscale_nodes
      tailscale_auth_key   = var.tailscale_auth_key != null ? var.tailscale_auth_key : ""
      hostname             = "${var.pool_name}-0"
    })
    : var.role == "server"
    ? templatefile("${path.module}/templates/cp-init.yaml.tpl", {
      rke2_version         = var.rke2_version
      rke2_token           = var.rke2_token
      control_plane_lb_ip  = var.control_plane_lb_ip
      node_ip              = null # assigned by Hetzner DHCP
      cluster_init         = false
      first_cp_ip          = var.first_cp_ip
      has_labels           = local.has_labels
      label_args           = local.label_args
      has_taints           = local.has_taints
      taint_args           = local.taint_args
      longhorn_volume_size = var.longhorn_volume_size
      enable_tailscale     = var.enable_tailscale_nodes
      tailscale_auth_key   = var.tailscale_auth_key != null ? var.tailscale_auth_key : ""
      hostname             = "${var.pool_name}-${count.index}"
    })
    : templatefile("${path.module}/templates/worker-init.yaml.tpl", {
      rke2_version         = var.rke2_version
      rke2_token           = var.rke2_token
      control_plane_lb_ip  = var.control_plane_lb_ip
      has_labels           = local.has_labels
      label_args           = local.label_args
      has_taints           = local.has_taints
      taint_args           = local.taint_args
      longhorn_volume_size = var.longhorn_volume_size
      enable_tailscale     = var.enable_tailscale_nodes
      tailscale_auth_key   = var.tailscale_auth_key != null ? var.tailscale_auth_key : ""
      hostname             = "${var.pool_name}-${count.index}"
    })
  )

  labels = merge(
    { cluster = split("-", var.pool_name)[0], pool = var.pool_name, role = var.role },
    var.labels
  )

  # For autoscaled pools: Terraform provisions the initial min_nodes but the
  # autoscaler manages the count thereafter. Prevent Terraform drift corrections
  # that would fight the autoscaler.
  lifecycle {
    ignore_changes = [
      user_data, # cloud-init is only applied at creation time
    ]
  }
}

# =============================================================================
# Private Network Attachment
# =============================================================================

resource "hcloud_server_network" "nodes" {
  count = var.node_count

  server_id  = hcloud_server.nodes[count.index].id
  network_id = var.network_id

  # Only assign a static IP to the first CP node. All other nodes use DHCP.
  # The static IP allows worker cloud-inits to reference a known join address.
  ip = (var.role == "server" && count.index == 0 && var.first_node_static_ip != null
    ? var.first_node_static_ip
    : null
  )
}

# =============================================================================
# Load Balancer Target Registration (control plane only)
# =============================================================================

resource "hcloud_load_balancer_target" "cp" {
  count = var.attach_to_lb ? var.node_count : 0

  type             = "server"
  load_balancer_id = var.lb_id
  server_id        = hcloud_server.nodes[count.index].id
  use_private_ip   = true

  depends_on = [hcloud_server_network.nodes]
}

# =============================================================================
# Firewall Attachment (if firewall_id passed through — handled in networking module)
# =============================================================================

# Note: Firewall attachment to servers happens via hcloud_firewall_attachment
# in the networking module (uses label selector for all cluster nodes).

# =============================================================================
# Longhorn Data Volumes (optional, per pool)
# =============================================================================

resource "hcloud_volume" "longhorn_data" {
  count    = var.longhorn_volume_size > 0 ? var.node_count : 0
  name     = "${var.pool_name}-longhorn-${count.index}"
  size     = var.longhorn_volume_size
  location = var.location
  format   = "ext4"

  labels = { cluster = split("-", var.pool_name)[0], pool = var.pool_name }

  lifecycle {
    # Prevent accidental deletion — data loss if Longhorn is running
    prevent_destroy = false # Set to true in production for critical clusters
  }
}

resource "hcloud_volume_attachment" "longhorn_data" {
  count = var.longhorn_volume_size > 0 ? var.node_count : 0

  volume_id = hcloud_volume.longhorn_data[count.index].id
  server_id = hcloud_server.nodes[count.index].id
  automount = true # Mounts under /dev/disk/by-id/scsi-0HC_Volume_<id>
}
