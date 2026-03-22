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

  # Cilium must finish before CSI can deploy — same reasoning as CCM:
  # CSI node pods require cluster networking to become Ready.
  depends_on = [kubernetes_secret_v1.hcloud_csi[0], helm_release.cilium]
}
