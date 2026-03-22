# =============================================================================
# Private Network
# When existing_network_id is null (default): create a new hcloud_network.
# When existing_network_id is set: use the existing network via a data source.
# Either way: always create a subnet for this cluster within the network.
# =============================================================================

resource "hcloud_network" "cluster" {
  count    = var.existing_network_id == null ? 1 : 0
  name     = "${var.cluster_name}-network"
  ip_range = var.network_cidr

  labels = {
    cluster = var.cluster_name
  }
}

data "hcloud_network" "existing" {
  count = var.existing_network_id != null ? 1 : 0
  id    = var.existing_network_id
}

resource "hcloud_network_subnet" "cluster" {
  network_id   = local.network_id
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
  network_id       = local.network_id
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
  # Resolve network ID and name from either the created or existing network
  network_id   = var.existing_network_id != null ? var.existing_network_id : hcloud_network.cluster[0].id
  network_name = var.existing_network_id != null ? data.hcloud_network.existing[0].name : hcloud_network.cluster[0].name

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
