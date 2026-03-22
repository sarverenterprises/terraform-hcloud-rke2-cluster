# =============================================================================
# Hetzner Firewall (optional)
# Rules derived from production rke2-primary cluster conventions.
# Security defaults:
#   - SSH (22): closed unless trusted_ssh_cidrs is set
#   - NodePort (30000-32767): closed unless nodeport_allowed_cidrs is set
#   - etcd/kubelet/RKE2 internal ports: restricted to cluster subnet only
# =============================================================================

resource "hcloud_firewall" "cluster" {
  count = var.enable_firewall ? 1 : 0
  name  = "${var.cluster_name}-firewall"

  labels = {
    cluster = var.cluster_name
  }

  # ---- ICMP ---------------------------------------------------------------
  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "Allow ICMP (ping)"
  }

  # ---- SSH (TCP 22) --------------------------------------------------------
  # Default: blocked. Set trusted_ssh_cidrs to enable.
  # Tip: use ["100.64.0.0/10"] when enable_tailscale_nodes=true.
  dynamic "rule" {
    for_each = length(var.trusted_ssh_cidrs) > 0 ? [1] : []
    content {
      direction   = "in"
      protocol    = "tcp"
      port        = "22"
      source_ips  = var.trusted_ssh_cidrs
      description = "SSH from trusted CIDRs"
    }
  }

  # ---- Kubernetes API server (TCP 6443) ------------------------------------
  # cluster_subnet_cidr is always included so the LB can forward health checks
  # and API traffic to CP nodes via private IP even when kube_api_allowed_cidrs=[].
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "6443"
    source_ips  = concat([var.cluster_subnet_cidr], var.kube_api_allowed_cidrs)
    description = "Kubernetes API server"
  }

  # ---- RKE2 supervisor / join endpoint (TCP 9345) -------------------------
  # Restricted to cluster subnet — only cluster nodes join the cluster
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "9345"
    source_ips  = [var.cluster_subnet_cidr]
    description = "RKE2 supervisor (internal only)"
  }

  # ---- kubelet API (TCP 10250) ---------------------------------------------
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "10250"
    source_ips  = [var.cluster_subnet_cidr]
    description = "kubelet API (internal only)"
  }

  # ---- etcd (TCP 2379-2380) -----------------------------------------------
  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "2379-2380"
    source_ips  = [var.cluster_subnet_cidr]
    description = "etcd (control plane internal only)"
  }

  # ---- Cilium VXLAN (UDP 8472) --------------------------------------------
  rule {
    direction   = "in"
    protocol    = "udp"
    port        = "8472"
    source_ips  = [var.cluster_subnet_cidr]
    description = "Cilium VXLAN overlay (internal only)"
  }

  # ---- NodePort (TCP 30000-32767) -----------------------------------------
  # Default: closed. Prefer Hetzner LB via CCM instead of NodePort.
  dynamic "rule" {
    for_each = length(var.nodeport_allowed_cidrs) > 0 ? [1] : []
    content {
      direction   = "in"
      protocol    = "tcp"
      port        = "30000-32767"
      source_ips  = var.nodeport_allowed_cidrs
      description = "NodePort services"
    }
  }
}
