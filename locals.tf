locals {
  # ==========================================================================
  # Name Prefix
  # ==========================================================================
  name_prefix = var.cluster_name

  # ==========================================================================
  # Control Plane
  # ==========================================================================

  # Effective location for control plane nodes
  control_plane_location = coalesce(var.control_plane_location, var.location)

  # Static private IP for the first control plane node.
  # Assigned explicitly so that worker cloud-inits can reference it at plan time
  # without a circular dependency. Uses the .10 address of the subnet host range.
  first_cp_private_ip = cidrhost(var.cluster_subnet_cidr, 10)

  # ==========================================================================
  # Per-Component Hetzner Tokens
  # ==========================================================================
  # try() handles the case where both the component token and the default token
  # are null (e.g. when HCLOUD_TOKEN is used for provider auth instead).
  effective_ccm_token        = try(coalesce(var.hcloud_ccm_token, var.hcloud_token), null)
  effective_csi_token        = try(coalesce(var.hcloud_csi_token, var.hcloud_token), null)
  effective_autoscaler_token = try(coalesce(var.hcloud_autoscaler_token, var.hcloud_token), null)

  # ==========================================================================
  # Worker Node Counts (for Longhorn replica computation)
  # ==========================================================================

  # Sum of all worker nodes: fixed pools use node_count, autoscaled use min_nodes
  total_worker_nodes = length(var.node_pools) == 0 ? 0 : sum([
    for p in var.node_pools :
    p.scaling_mode == "autoscaled" ? p.min_nodes : p.node_count
  ])

  # Longhorn replica count: never exceed worker node count; cap at 3 for HA
  longhorn_default_replicas = min(local.total_worker_nodes, 3)

  # ==========================================================================
  # Autoscaler Cloud-Inits
  #
  # Rendered here (root module) rather than inside modules/addons so that the
  # templatefile() path is always relative to the root, which works whether
  # the module is sourced locally or from a Git remote. The addons module
  # receives the rendered strings via var.autoscaler_pool_cloud_inits.
  # ==========================================================================
  autoscaler_pool_cloud_inits = {
    for p in var.node_pools : "${var.cluster_name}-${p.name}" => templatefile(
      "${path.module}/modules/node-pool/templates/worker-init.yaml.tpl",
      {
        rke2_version         = var.rke2_version
        rke2_token           = random_password.rke2_token.result
        control_plane_lb_ip  = module.networking.control_plane_lb_ip
        has_labels           = length(p.labels) > 0
        label_args           = join("\n", [for k, v in p.labels : "  - \"${k}=${v}\""])
        has_taints           = length(p.taints) > 0
        taint_args           = join("\n", [for t in p.taints : "  - \"${t.key}=${t.value}:${t.effect}\""])
        longhorn_volume_size = p.longhorn_volume_size
        enable_tailscale     = var.enable_tailscale_nodes
        tailscale_auth_key   = coalesce(var.tailscale_node_auth_key, "")
        # Placeholder hostname — the autoscaler appends a unique suffix per provisioned node
        hostname = "${var.cluster_name}-${p.name}-autoscale"
      }
    ) if p.scaling_mode == "autoscaled"
  }

  # ==========================================================================
  # Kubeconfig (written to disk by null_resource.fetch_kubeconfig)
  # ==========================================================================
  kubeconfig_path = "${path.root}/.kube/${var.cluster_name}.yaml"
}
