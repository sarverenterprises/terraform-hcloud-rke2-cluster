# =============================================================================
# External-DNS (two Cloudflare deployments)
#
# Two separate releases are required because Cloudflare's proxy (orange-cloud)
# and DNS-only (grey-cloud) modes must be driven by separate external-dns
# instances — each filtered by a distinct annotation value.
#
#   external-dns-proxied  — annotationFilter: cloudflare-proxied=true
#   external-dns-dnsonly  — annotationFilter: cloudflare-proxied!=true
#
# Both instances share a single Cloudflare API token Secret.
#
# Deployed only when var.enable_external_dns == true.
# =============================================================================

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  metadata {
    name = "external-dns"
  }
}

# ---------------------------------------------------------------------------
# Secret: Cloudflare API token
# Stored as a Secret rather than inline Helm values to prevent the token
# appearing in the Helm release manifest (stored in-cluster as a ConfigMap).
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "cloudflare_api_token_external_dns" {
  count = var.enable_external_dns ? 1 : 0

  metadata {
    name      = "cloudflare-api-token"
    namespace = kubernetes_namespace_v1.external_dns[0].metadata[0].name
  }

  data = {
    CF_API_TOKEN = var.cloudflare_api_token
  }
}

# ---------------------------------------------------------------------------
# Helm release: external-dns-proxied
# Handles records for public-facing services annotated with
# external-dns.alpha.kubernetes.io/cloudflare-proxied=true
# ---------------------------------------------------------------------------
resource "helm_release" "external_dns_proxied" {
  count = var.enable_external_dns ? 1 : 0

  name       = "external-dns-proxied"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  namespace  = kubernetes_namespace_v1.external_dns[0].metadata[0].name
  version    = var.external_dns_chart_version

  wait    = true
  atomic  = true
  timeout = 300

  values = [
    yamlencode({
      provider = {
        name = "cloudflare"
      }
      env = [
        {
          name = "CF_API_TOKEN"
          valueFrom = {
            secretKeyRef = {
              name = kubernetes_secret_v1.cloudflare_api_token_external_dns[0].metadata[0].name
              key  = "CF_API_TOKEN"
            }
          }
        }
      ]
      txtOwnerId = "${var.cluster_name}-proxied"
      domainFilters = [
        var.cloudflare_zone
      ]
      # Only manage records for services/ingresses explicitly requesting proxy mode.
      annotationFilter = "external-dns.alpha.kubernetes.io/cloudflare-proxied=true"
      cloudflare = {
        proxied = true
      }
    })
  ]

  depends_on = [kubernetes_secret_v1.cloudflare_api_token_external_dns]
}

# ---------------------------------------------------------------------------
# Helm release: external-dns-dnsonly
# Handles all other records (DNS-only / grey cloud), including those used
# by cert-manager for ACME DNS-01 challenges which must not be proxied.
# ---------------------------------------------------------------------------
resource "helm_release" "external_dns_dnsonly" {
  count = var.enable_external_dns ? 1 : 0

  name       = "external-dns-dnsonly"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  namespace  = kubernetes_namespace_v1.external_dns[0].metadata[0].name
  version    = var.external_dns_chart_version

  wait    = true
  atomic  = true
  timeout = 300

  values = [
    yamlencode({
      provider = {
        name = "cloudflare"
      }
      env = [
        {
          name = "CF_API_TOKEN"
          valueFrom = {
            secretKeyRef = {
              name = kubernetes_secret_v1.cloudflare_api_token_external_dns[0].metadata[0].name
              key  = "CF_API_TOKEN"
            }
          }
        }
      ]
      txtOwnerId = "${var.cluster_name}-dnsonly"
      domainFilters = [
        var.cloudflare_zone
      ]
      # Manage all records NOT explicitly requesting proxy mode (!=true covers
      # both absent annotation and cloudflare-proxied=false).
      annotationFilter = "external-dns.alpha.kubernetes.io/cloudflare-proxied!=true"
      cloudflare = {
        proxied = false
      }
    })
  ]

  depends_on = [kubernetes_secret_v1.cloudflare_api_token_external_dns]
}
