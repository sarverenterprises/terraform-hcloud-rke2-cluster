# =============================================================================
# System Upgrade Controller
#
# Installs Rancher's System Upgrade Controller via the official Helm chart.
# SUC watches for Plan CRDs and orchestrates rolling OS and RKE2 upgrades
# across nodes with configurable concurrency and drain policies.
#
# No custom values are needed — default chart values are sufficient. Operators
# create Plan resources after the controller is running.
#
# Deployed only when var.enable_system_upgrade_controller == true.
# =============================================================================

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "system_upgrade" {
  count = var.enable_system_upgrade_controller ? 1 : 0

  metadata {
    name = "system-upgrade"
  }
}

# ---------------------------------------------------------------------------
# Helm release: system-upgrade-controller
# ---------------------------------------------------------------------------
resource "helm_release" "system_upgrade_controller" {
  count = var.enable_system_upgrade_controller ? 1 : 0

  name       = "system-upgrade-controller"
  repository = "https://charts.rancher.io"
  chart      = "system-upgrade-controller"
  namespace  = kubernetes_namespace_v1.system_upgrade[0].metadata[0].name
  version    = var.system_upgrade_controller_chart_version

  wait    = true
  atomic  = true
  timeout = 300

  depends_on = [
    kubernetes_namespace_v1.system_upgrade,
    null_resource.wait_for_coredns,
  ]
}
