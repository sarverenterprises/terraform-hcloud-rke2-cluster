# =============================================================================
# Ingress Controller — Traefik or NGINX
#
# Exactly one ingress controller is deployed based on var.ingress_type.
# The count trick isolates each controller behind its own flag so Terraform
# can plan cleanly without conditional provider blocks.
#
#   traefik  — Traefik v3 proxy + Gateway API CRDs via null_resource
#   nginx    — ingress-nginx (community chart, ingress-nginx namespace)
#
# Deployed only when var.enable_ingress == true.
# =============================================================================

locals {
  deploy_traefik = var.enable_ingress && var.ingress_type == "traefik"
  deploy_nginx   = var.enable_ingress && var.ingress_type == "nginx"
}

# =============================================================================
# Traefik path
# =============================================================================

# ---------------------------------------------------------------------------
# Namespace: traefik
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "traefik" {
  count = local.deploy_traefik ? 1 : 0

  metadata {
    name = "traefik"
  }
}

# ---------------------------------------------------------------------------
# Helm release: traefik
# The Hetzner LB annotations ensure the cloud load balancer that fronts
# Traefik uses the node's private IP rather than public IP for health checks,
# which is required when nodes do not have public IPs.
# isDefaultClass=true makes Traefik the cluster-wide default IngressClass.
# ---------------------------------------------------------------------------
resource "helm_release" "traefik" {
  count = local.deploy_traefik ? 1 : 0

  name       = "traefik"
  repository = "https://helm.traefik.io/traefik"
  chart      = "traefik"
  namespace  = kubernetes_namespace_v1.traefik[0].metadata[0].name
  version    = var.traefik_chart_version

  wait    = true
  atomic  = true
  timeout = 300

  values = [
    yamlencode({
      service = {
        annotations = {
          # Hetzner CCM reads these to configure the cloud load balancer.
          # use-private-ip is required when worker nodes have no public IPs.
          "load-balancer.hetzner.cloud/use-private-ip" = "true"
        }
      }
      ingressClass = {
        enabled        = true
        isDefaultClass = true
      }
    })
  ]

  depends_on = [kubernetes_namespace_v1.traefik]
}

# ---------------------------------------------------------------------------
# Gateway API CRDs
# Installed via kubectl so the CRD set matches the upstream release exactly.
# The caller must have KUBECONFIG set in the environment (or use the
# KUBE_CONFIG_PATH env var) before running terraform apply.
#
# The trigger on helm_release.traefik[0].id ensures this runs (or re-runs)
# whenever the Traefik release is replaced, keeping CRD lifecycle coupled to
# the controller that implements them.
# ---------------------------------------------------------------------------
resource "null_resource" "gateway_api_crds" {
  count = local.deploy_traefik ? 1 : 0

  triggers = {
    # Re-apply when the Traefik release changes (e.g. version bump).
    traefik_release_id = helm_release.traefik[0].id
  }

  provisioner "local-exec" {
    command = "kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml"
  }

  depends_on = [helm_release.traefik]
}

# =============================================================================
# NGINX path
# =============================================================================

# ---------------------------------------------------------------------------
# Namespace: ingress-nginx
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "ingress_nginx" {
  count = local.deploy_nginx ? 1 : 0

  metadata {
    name = "ingress-nginx"
  }
}

# ---------------------------------------------------------------------------
# Helm release: ingress-nginx
# controller.ingressClassResource.default=true makes NGINX the cluster-wide
# default IngressClass so Ingress objects without an explicit class annotation
# are handled by this controller.
# ---------------------------------------------------------------------------
resource "helm_release" "ingress_nginx" {
  count = local.deploy_nginx ? 1 : 0

  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = kubernetes_namespace_v1.ingress_nginx[0].metadata[0].name
  version    = "~> 4.11"

  wait    = true
  atomic  = true
  timeout = 300

  values = [
    yamlencode({
      controller = {
        ingressClassResource = {
          default = true
        }
      }
    })
  ]

  depends_on = [kubernetes_namespace_v1.ingress_nginx]
}
