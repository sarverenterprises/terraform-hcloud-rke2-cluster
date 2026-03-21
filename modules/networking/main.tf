# =============================================================================
# Private Network
# Always provisioned — required for Hetzner CCM (correct node internal IPs)
# and Cilium encrypted pod networking (VXLAN over private net).
# =============================================================================

resource "hcloud_network" "cluster" {
  name     = "${var.cluster_name}-network"
  ip_range = var.network_cidr

  labels = {
    cluster = var.cluster_name
  }
}

resource "hcloud_network_subnet" "cluster" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = local.network_zone
  ip_range     = var.cluster_subnet_cidr
}

# =============================================================================
# Placement Group (spread — one node per physical host where possible)
# =============================================================================

resource "hcloud_placement_group" "control_plane" {
  name = "${var.cluster_name}-cp-spread"
  type = "spread"

  labels = {
    cluster = var.cluster_name
  }
}

# =============================================================================
# Control Plane Load Balancer
# =============================================================================

resource "hcloud_load_balancer" "control_plane" {
  name               = "${var.cluster_name}-cp-lb"
  load_balancer_type = "lb11"
  location           = var.location

  labels = {
    cluster = var.cluster_name
  }
}

# Attach the LB to the private network so CCM can reach nodes via private IPs
resource "hcloud_load_balancer_network" "control_plane" {
  load_balancer_id = hcloud_load_balancer.control_plane.id
  network_id       = hcloud_network.cluster.id
}

# Kubernetes API server (port 6443)
resource "hcloud_load_balancer_service" "kube_api" {
  load_balancer_id = hcloud_load_balancer.control_plane.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443

  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

# RKE2 supervisor / join endpoint (port 9345)
resource "hcloud_load_balancer_service" "rke2_supervisor" {
  load_balancer_id = hcloud_load_balancer.control_plane.id
  protocol         = "tcp"
  listen_port      = 9345
  destination_port = 9345

  health_check {
    protocol = "tcp"
    port     = 9345
    interval = 10
    timeout  = 5
    retries  = 3
  }
}

# =============================================================================
# Locals
# =============================================================================

locals {
  # Map Hetzner location to network zone
  network_zone = lookup(
    {
      "ash"  = "us-east"
      "hel1" = "eu-central"
      "fsn1" = "eu-central"
      "nbg1" = "eu-central"
    },
    var.location,
    "eu-central"
  )
}
