# =============================================================================
# Hetzner Cloud Controller Manager (CCM)
#
# Manages Hetzner-specific Kubernetes resources: node addressing, load
# balancers, and private network routes. Must run before CSI because CSI
# depends on node labels CCM applies.
#
# Deployed only when var.enable_hcloud_ccm == true.
# =============================================================================

# ---------------------------------------------------------------------------
# Secret: hcloud credentials for CCM
# Token + private network name are passed via a Kubernetes Secret so they
# are never present in Helm values (which appear in plain-text in the
# release manifest stored in the cluster).
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "hcloud_ccm" {
  count = var.enable_hcloud_ccm ? 1 : 0

  metadata {
    name      = "hcloud"
    namespace = "kube-system"
  }

  data = {
    token   = var.hcloud_ccm_token
    network = var.private_network_name
  }
}

# ---------------------------------------------------------------------------
# Helm release: hcloud-ccm
# ---------------------------------------------------------------------------
resource "helm_release" "hcloud_ccm" {
  count = var.enable_hcloud_ccm ? 1 : 0

  name       = "hcloud-ccm"
  repository = "https://charts.hetzner.cloud"
  chart      = "hcloud-cloud-controller-manager"
  namespace  = "kube-system"
  version    = var.hcloud_ccm_chart_version

  wait    = true
  atomic  = true
  timeout = 300

  values = [
    yamlencode({
      networking = {
        enabled = true
        # RKE2 default pod CIDR — must match cluster-cidr in RKE2 server config
        clusterCIDR = "10.42.0.0/16"
      }
    })
  ]

  # Cilium must finish before CCM can deploy: CCM pods require cluster
  # networking to become Ready, and networking is provided by Cilium.
  # Without this dependency, Terraform deploys CCM in parallel with Cilium
  # and CCM times out (5 min) waiting for pods that can't start until
  # Cilium has set up the node network stack.
  depends_on = [kubernetes_secret_v1.hcloud_ccm[0], helm_release.cilium]
}
