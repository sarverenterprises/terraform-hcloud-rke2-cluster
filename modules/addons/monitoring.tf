# =============================================================================
# kube-prometheus-stack
#
# Installs kube-prometheus-stack (Prometheus + Alertmanager + Grafana +
# kube-state-metrics + node-exporter) via the Prometheus Community Helm chart.
#
# Storage is backed by Longhorn (longhorn-rwo StorageClass). If Longhorn is
# not enabled the operator must override the storageSpec values to point at
# a StorageClass that exists in the cluster, or remove the storageSpec blocks
# entirely.
#
# Grafana ingress is configured only when var.grafana_hostname is set. The
# ingress class is Traefik — adjust the annotation if using a different
# ingress controller.
#
# timeout = 600: this chart deploys many resources (CRDs, DaemonSets,
# Deployments) and routinely takes 3–8 minutes on a freshly provisioned
# cluster.
#
# Deployed only when var.enable_monitoring == true.
# =============================================================================

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "monitoring" {
  count = var.enable_monitoring ? 1 : 0

  metadata {
    name = "monitoring"
  }
}

# ---------------------------------------------------------------------------
# Local: Grafana ingress config
#
# Built as a local to keep the yamlencode call readable. When grafana_hostname
# is null the ingress block disables itself so the chart does not attempt to
# create an Ingress resource.
# ---------------------------------------------------------------------------
locals {
  grafana_ingress = {
    enabled     = var.grafana_hostname != null
    annotations = { "kubernetes.io/ingress.class" = "traefik" }
    hosts       = var.grafana_hostname != null ? [var.grafana_hostname] : []
  }
}

# ---------------------------------------------------------------------------
# Helm release: kube-prometheus-stack
# ---------------------------------------------------------------------------
resource "random_password" "grafana_admin" {
  count   = var.enable_monitoring ? 1 : 0
  length  = 24
  special = true
}

resource "helm_release" "kube_prometheus_stack" {
  count = var.enable_monitoring ? 1 : 0

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = kubernetes_namespace_v1.monitoring[0].metadata[0].name
  version    = var.kube_prometheus_stack_chart_version

  wait    = true
  atomic  = true
  timeout = 600

  lifecycle {
    precondition {
      condition     = !(var.enable_monitoring && !var.enable_longhorn)
      error_message = "enable_monitoring requires enable_longhorn = true (Prometheus/Alertmanager use longhorn-rwo StorageClass)."
    }
  }

  values = [
    yamlencode({
      grafana = {
        enabled       = true
        adminPassword = random_password.grafana_admin[0].result
        ingress       = local.grafana_ingress
      }

      prometheus = {
        prometheusSpec = {
          retention = "30d"
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "longhorn-rwo"
                resources = {
                  requests = {
                    storage = "50Gi"
                  }
                }
              }
            }
          }
        }
      }

      alertmanager = {
        alertmanagerSpec = {
          storage = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "longhorn-rwo"
                resources = {
                  requests = {
                    storage = "10Gi"
                  }
                }
              }
            }
          }
        }
      }
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.monitoring,
    helm_release.longhorn,
    kubernetes_manifest.longhorn_sc_rwo,
  ]
}
