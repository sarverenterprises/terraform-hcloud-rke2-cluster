# =============================================================================
# Cluster Autoscaler for Hetzner Cloud
#
# Deploys the Kubernetes Cluster Autoscaler with the Hetzner Cloud provider.
# Uses HCLOUD_CLUSTER_CONFIG (current API) — NOT the legacy HCLOUD_CLOUD_INIT.
#
# The autoscaler manages only pools where scaling_mode == "autoscaled".
# Fixed-size pools are ignored.
#
# Deployed only when var.enable_cluster_autoscaler == true.
# =============================================================================

locals {
  # Filter to only pools that opt into autoscaling
  autoscaled_pools = [for p in var.node_pools : p if p.scaling_mode == "autoscaled"]

  # HCLOUD_CLUSTER_CONFIG JSON structure (current Hetzner autoscaler API).
  # - imagesForArch: maps CPU arch to Hetzner OS image name or ID
  # - nodeConfigs: keyed by the exact pool name used in --nodes flags
  #   - cloudInit: raw cloud-init YAML string (NOT base64-encoded here;
  #                the entire cluster_config JSON is base64-encoded below)
  #   - labels/taints: empty maps/lists — labels and taints are injected
  #                    via cloud-init config.yaml instead
  #
  # Cloud-inits are pre-rendered in the root module and passed in via
  # var.autoscaler_pool_cloud_inits to avoid cross-module template path
  # violations when this module is sourced from a Git remote.
  cluster_config = {
    imagesForArch = {
      amd64 = var.os_image
      arm64 = var.os_image
    }
    nodeConfigs = {
      for pool_name, cloud_init in var.autoscaler_pool_cloud_inits : pool_name => {
        cloudInit = cloud_init
        labels    = {}
        taints    = []
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Secret: Hetzner credentials + cluster config for the autoscaler
#
# HCLOUD_TOKEN        — Hetzner API token scoped to autoscaler actions only
# HCLOUD_CLUSTER_CONFIG — base64-encoded JSON describing node pools, OS image,
#                         and per-pool cloud-init (current API, replaces
#                         deprecated HCLOUD_CLOUD_INIT)
#
# Sensitive data is passed via Secret so it never appears in Helm values,
# which are stored in plain-text in cluster ConfigMaps.
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "hcloud_autoscaler" {
  count = var.enable_cluster_autoscaler ? 1 : 0

  metadata {
    name      = "hcloud-autoscaler"
    namespace = "kube-system"
  }

  data = {
    HCLOUD_TOKEN          = var.hcloud_autoscaler_token
    HCLOUD_CLUSTER_CONFIG = base64encode(jsonencode(local.cluster_config))
  }
}

# ---------------------------------------------------------------------------
# Helm release: cluster-autoscaler
#
# Uses the upstream Kubernetes SIG Autoscaling chart.
# autoDiscovery is disabled; node groups are declared explicitly so the
# autoscaler only touches pools we explicitly opt in.
# ---------------------------------------------------------------------------
resource "helm_release" "cluster_autoscaler" {
  count = var.enable_cluster_autoscaler ? 1 : 0

  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.cluster_autoscaler_chart_version
  namespace  = "kube-system"

  wait    = true
  atomic  = true
  timeout = 300

  values = [
    yamlencode({
      cloudProvider = "hetzner"

      image = {
        # Pin to a specific tag so upgrades are intentional and auditable
        tag = var.cluster_autoscaler_image_tag
      }

      # Mount the hcloud-autoscaler Secret as environment variables.
      # HCLOUD_TOKEN and HCLOUD_CLUSTER_CONFIG are consumed from the Secret.
      extraEnvFrom = [
        {
          secretRef = {
            name = "hcloud-autoscaler"
          }
        }
      ]

      # Explicit node group declaration — autoDiscovery not used with Hetzner
      autoDiscovery = {
        enabled = false
      }

      # One entry per autoscaled pool.
      # name must exactly match the pool name key in HCLOUD_CLUSTER_CONFIG nodeConfigs.
      autoscalingGroups = [
        for p in local.autoscaled_pools : {
          name    = "${var.cluster_name}-${p.name}"
          minSize = p.min_nodes
          maxSize = p.max_nodes
        }
      ]

      rbac = {
        serviceAccount = {
          create = true
        }
      }

      extraArgs = {
        # Allow scale-down of nodes running system pods (DaemonSets are excluded automatically)
        skip-nodes-with-system-pods = "false"
        # Allow scale-down of nodes with local storage
        skip-nodes-with-local-storage = "false"
        # Consolidate similar node groups when scaling up to prevent imbalance
        balance-similar-node-groups = "true"
        # least-waste expander prefers the group that wastes the fewest resources
        expander = "least-waste"
      }
    })
  ]

  # Secret must exist before the autoscaler pod starts — it reads both
  # HCLOUD_TOKEN and HCLOUD_CLUSTER_CONFIG from it at startup.
  depends_on = [kubernetes_secret_v1.hcloud_autoscaler[0]]
}
