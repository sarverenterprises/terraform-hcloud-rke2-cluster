# =============================================================================
# Hetzner CSI Driver
#
# Provides persistent volume support backed by Hetzner Cloud Volumes.
# Creates a `hcloud-volumes` StorageClass and the standard CSI sidecars.
#
# Deployed only when var.enable_hcloud_csi == true.
# =============================================================================

# ---------------------------------------------------------------------------
# Secret: hcloud credentials for CSI
# Separate secret from CCM — different token scope and trust domain.
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "hcloud_csi" {
  count = var.enable_hcloud_csi ? 1 : 0

  metadata {
    name      = "hcloud-csi"
    namespace = "kube-system"
  }

  data = {
    token = var.hcloud_csi_token
  }
}

# ---------------------------------------------------------------------------
# Helm release: hcloud-csi
# ---------------------------------------------------------------------------
resource "helm_release" "hcloud_csi" {
  count = var.enable_hcloud_csi ? 1 : 0

  name       = "hcloud-csi"
  repository = "https://charts.hetzner.cloud"
  chart      = "hcloud-csi"
  namespace  = "kube-system"
  version    = var.hcloud_csi_chart_version

  wait    = true
  atomic  = true
  timeout = 300

  # wait_for_coredns ensures CoreDNS is up before CSI starts. The CSI
  # controller resolves api.hetzner.cloud by hostname; without DNS it exits
  # with code 2 and crash-loops until CoreDNS becomes available (~25 restarts
  # on a fresh deploy). Waiting here eliminates that crash-loop entirely.
  depends_on = [kubernetes_secret_v1.hcloud_csi[0], null_resource.wait_for_coredns]
}
