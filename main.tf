# =============================================================================
# Cluster Join Token
# =============================================================================

resource "random_password" "rke2_token" {
  length  = 64
  special = false

  lifecycle {
    # Rotating this token invalidates all node cloud-inits. Do not change after
    # initial apply without re-provisioning ALL nodes.
    prevent_destroy = true
  }
}

# =============================================================================
# Networking
# =============================================================================

module "networking" {
  source = "./modules/networking"

  cluster_name           = var.cluster_name
  location               = local.control_plane_location
  network_cidr           = var.network_cidr
  cluster_subnet_cidr    = var.cluster_subnet_cidr
  existing_network_id    = var.existing_network_id
  enable_firewall        = var.enable_firewall
  trusted_ssh_cidrs      = var.trusted_ssh_cidrs
  kube_api_allowed_cidrs = var.kube_api_allowed_cidrs
  nodeport_allowed_cidrs = var.nodeport_allowed_cidrs
  lb_private_ip          = var.lb_private_ip
}

# =============================================================================
# Control Plane (always 3 nodes — HA embedded etcd)
# =============================================================================

module "control_plane" {
  source = "./modules/node-pool"

  pool_name                = "${var.cluster_name}-cp"
  cluster_name             = var.cluster_name
  role                     = "server"
  node_count               = 3
  server_type              = var.control_plane_server_type
  location                 = local.control_plane_location
  os_image                 = var.os_image
  ssh_keys                 = var.ssh_keys
  network_id               = module.networking.network_id
  subnet_id                = module.networking.subnet_id
  placement_group_id       = var.enable_placement_group ? module.networking.placement_group_id : null
  lb_id                    = module.networking.lb_id
  attach_to_lb             = true
  lb_network_attachment_id = module.networking.lb_network_attachment_id
  assign_public_ip         = true

  # Assign the first CP a known static private IP to avoid circular dependencies
  # in worker cloud-inits that reference the first CP's join endpoint.
  first_node_static_ip = local.first_cp_private_ip

  # Cloud-init
  rke2_version        = var.rke2_version
  rke2_token          = random_password.rke2_token.result
  control_plane_lb_ip = module.networking.private_lb_ip
  first_cp_ip         = local.first_cp_private_ip
  cluster_subnet_cidr = var.cluster_subnet_cidr
  pod_cidr            = var.pod_cidr
  service_cidr        = var.service_cidr

  # Security
  enable_tailscale_nodes = var.enable_tailscale_nodes
  tailscale_auth_key     = var.tailscale_node_auth_key

  # CP nodes never get dedicated Longhorn volumes
  longhorn_volume_size = 0
  scaling_mode         = "fixed"

  labels = { "node-role" = "control-plane" }
  taints = []
}

# =============================================================================
# Worker Node Pools
# =============================================================================

module "worker_pools" {
  # for_each gives stable resource addresses when pools are added/removed
  for_each = { for pool in var.node_pools : pool.name => pool }

  source = "./modules/node-pool"

  pool_name    = "${var.cluster_name}-${each.key}"
  cluster_name = var.cluster_name
  role         = "agent"
  node_count   = each.value.scaling_mode == "autoscaled" ? each.value.min_nodes : each.value.node_count
  server_type  = each.value.server_type
  location     = coalesce(each.value.location, var.location)
  os_image     = var.os_image
  ssh_keys     = var.ssh_keys
  network_id   = module.networking.network_id
  subnet_id    = module.networking.subnet_id

  # Worker pools do not use a placement group or LB registration
  placement_group_id   = null
  lb_id                = null
  first_node_static_ip = null

  assign_public_ip = each.value.assign_public_ip
  labels           = each.value.labels
  taints           = each.value.taints
  scaling_mode     = each.value.scaling_mode

  # Cloud-init
  rke2_version        = var.rke2_version
  rke2_token          = random_password.rke2_token.result
  control_plane_lb_ip = module.networking.private_lb_ip
  first_cp_ip         = local.first_cp_private_ip
  cluster_subnet_cidr = var.cluster_subnet_cidr

  # Security
  enable_tailscale_nodes = var.enable_tailscale_nodes
  tailscale_auth_key     = var.tailscale_node_auth_key

  longhorn_volume_size = each.value.longhorn_volume_size
}

# =============================================================================
# Kubeconfig Retrieval
#
# IMPORTANT: This requires the first control plane to have a public IP and
# for var.ssh_private_key to be set. The kubeconfig is written to
# .kube/<cluster_name>.yaml in the caller's working directory.
#
# Two-phase apply: On initial provisioning, run:
#   1. terraform apply -target=module.control_plane -target=module.worker_pools \
#              -target=null_resource.wait_for_cluster
#   2. terraform apply
# =============================================================================

resource "null_resource" "wait_for_cluster" {
  depends_on = [module.control_plane]

  triggers = {
    cp_ids = join(",", module.control_plane.server_ids)
  }

  connection {
    type        = "ssh"
    host        = module.control_plane.first_node_public_ip
    user        = "root"
    private_key = var.ssh_private_key
    timeout     = "15m"
  }

  provisioner "remote-exec" {
    inline = [
      # Wait for RKE2 server service to be active
      "until systemctl is-active rke2-server --quiet 2>/dev/null; do echo 'Waiting for rke2-server...'; sleep 10; done",
      # Wait for the kubeconfig file to appear
      "until [ -f /etc/rancher/rke2/rke2.yaml ]; do echo 'Waiting for kubeconfig...'; sleep 5; done",
      # Wait for the API server to be reachable
      "timeout 300 bash -c 'until /var/lib/rancher/rke2/bin/kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get nodes --request-timeout=5s &>/dev/null; do sleep 10; done'",
      "echo 'Cluster API server ready.'",
    ]
  }
}

resource "null_resource" "fetch_kubeconfig" {
  depends_on = [null_resource.wait_for_cluster]

  triggers = {
    cp_ids = join(",", module.control_plane.server_ids)
    lb_ip  = module.networking.control_plane_lb_ip
  }

  provisioner "local-exec" {
    command     = <<-EOT
      mkdir -p "${path.root}/.kube"
      ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR \
        -i <(printf '%s' "$SSHKEY") \
        root@${module.control_plane.first_node_public_ip} \
        "cat /etc/rancher/rke2/rke2.yaml" \
        | sed 's|https://127.0.0.1:6443|https://${module.networking.private_lb_ip}:6443|g' \
        > "${local.kubeconfig_path}"
      chmod 600 "${local.kubeconfig_path}"
      echo "Kubeconfig written to ${local.kubeconfig_path}"
    EOT
    interpreter = ["/bin/bash", "-c"]
    environment = {
      SSHKEY = var.ssh_private_key
    }
  }
}

# =============================================================================
# Kubeconfig State Persistence
#
# Stores the kubeconfig in Terraform state so that HCP Terraform remote runs
# (which have no persistent filesystem between phases) can access it in Phase 2.
# The terraform_data resource's output attribute is persisted in state, unlike
# null_resource triggers or data "local_file" which require the file on disk.
# =============================================================================

resource "terraform_data" "kubeconfig_store" {
  depends_on = [null_resource.fetch_kubeconfig]

  # Re-run whenever the kubeconfig file changes (new cluster or LB IP change).
  triggers_replace = [
    join(",", module.control_plane.server_ids),
    module.networking.control_plane_lb_ip,
  ]

  input = sensitive(fileexists(local.kubeconfig_path) ? file(local.kubeconfig_path) : "")
}

# =============================================================================
# Add-ons
# Called after the cluster is ready. Requires Helm + Kubernetes providers to be
# configured by the root module (examples/) using the fetched kubeconfig.
# =============================================================================

module "addons" {
  source = "./modules/addons"

  cluster_name    = var.cluster_name
  kubeconfig_path = local.kubeconfig_path

  # Hetzner tokens (per-component for least-privilege)
  hcloud_ccm_token        = local.effective_ccm_token
  hcloud_csi_token        = local.effective_csi_token
  hcloud_autoscaler_token = local.effective_autoscaler_token

  private_network_name = module.networking.network_name
  private_network_id   = module.networking.network_id
  pod_cidr             = var.pod_cidr

  # Worker pool info for autoscaler HCLOUD_CLUSTER_CONFIG
  node_pools                  = var.node_pools
  autoscaler_pool_cloud_inits = local.autoscaler_pool_cloud_inits
  rke2_cluster_token          = random_password.rke2_token.result
  rke2_version                = var.rke2_version
  control_plane_lb_ip         = module.networking.private_lb_ip
  cluster_subnet_cidr         = var.cluster_subnet_cidr
  os_image                    = var.os_image

  # Longhorn replica count computed from total worker nodes
  longhorn_default_replicas = local.longhorn_default_replicas

  # Tailscale for autoscaler cloud-init
  enable_tailscale_nodes  = var.enable_tailscale_nodes
  tailscale_node_auth_key = var.tailscale_node_auth_key

  # Add-on flags
  enable_hcloud_ccm         = var.enable_hcloud_ccm
  enable_hcloud_csi         = var.enable_hcloud_csi
  enable_external_dns       = var.enable_external_dns
  enable_cert_manager       = var.enable_cert_manager
  enable_ingress            = var.enable_ingress
  ingress_type              = var.ingress_type
  enable_longhorn           = var.enable_longhorn
  longhorn_rwx_mode         = var.longhorn_rwx_mode
  enable_cluster_autoscaler = var.enable_cluster_autoscaler
  autoscaler_rbac_level     = var.autoscaler_rbac_level
  enable_flux               = var.enable_flux
  flux_deploy_key_mode      = var.flux_deploy_key_mode
  enable_monitoring         = var.enable_monitoring
  grafana_hostname          = var.grafana_hostname
  enable_tailscale_operator = var.enable_tailscale_operator

  # Cloudflare
  cloudflare_api_token = var.cloudflare_api_token
  cloudflare_zone_id   = var.cloudflare_zone_id
  cloudflare_zone      = var.cloudflare_zone

  # GitHub / Flux
  github_token     = var.github_token
  flux_github_org  = var.flux_github_org
  flux_github_repo = var.flux_github_repo
  flux_branch      = var.flux_branch
  flux_path        = var.flux_path

  # Tailscale operator
  tailscale_operator_auth_key = var.tailscale_operator_auth_key

  # Argo CD
  enable_argocd               = var.enable_argocd
  argocd_hostname             = var.argocd_hostname
  argocd_github_client_id     = var.argocd_github_client_id
  argocd_github_client_secret = var.argocd_github_client_secret
  argocd_dex_connectors       = var.argocd_dex_connectors

  # Chart versions
  cilium_chart_version             = var.cilium_chart_version
  hcloud_ccm_chart_version         = var.hcloud_ccm_chart_version
  hcloud_csi_chart_version         = var.hcloud_csi_chart_version
  longhorn_chart_version           = var.longhorn_chart_version
  cert_manager_chart_version       = var.cert_manager_chart_version
  external_dns_chart_version       = var.external_dns_chart_version
  traefik_chart_version            = var.traefik_chart_version
  flux_version                     = var.flux_version
  cluster_autoscaler_chart_version = var.cluster_autoscaler_chart_version
  cluster_autoscaler_image_tag     = var.cluster_autoscaler_image_tag
  argocd_chart_version             = var.argocd_chart_version
  argo_rollouts_chart_version      = var.argo_rollouts_chart_version

  depends_on = [null_resource.fetch_kubeconfig]
}
