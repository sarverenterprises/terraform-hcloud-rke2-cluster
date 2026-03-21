# =============================================================================
# cert-manager + Cloudflare ClusterIssuer
#
# Installs cert-manager via Helm (with CRDs) and provisions a
# letsencrypt-prod ClusterIssuer that uses Cloudflare DNS-01 challenges.
# A dedicated Secret carries the Cloudflare API token for cert-manager so
# it is separate from the external-dns token (different Secret names allow
# independent rotation).
#
# Deployed only when var.enable_cert_manager == true.
# =============================================================================

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "cert_manager" {
  count = var.enable_cert_manager ? 1 : 0

  metadata {
    name = "cert-manager"
  }
}

# ---------------------------------------------------------------------------
# Secret: Cloudflare API token for cert-manager DNS-01 solver
# Must exist before the ClusterIssuer is applied so cert-manager can read it
# when processing the first certificate request.
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "cloudflare_api_token_cert_manager" {
  count = var.enable_cert_manager ? 1 : 0

  metadata {
    name      = "cloudflare-api-token-certmanager"
    namespace = kubernetes_namespace_v1.cert_manager[0].metadata[0].name
  }

  data = {
    api-token = var.cloudflare_api_token
  }
}

# ---------------------------------------------------------------------------
# Helm release: cert-manager
# installCRDs=true is the recommended approach for Helm-managed cert-manager
# deployments; it keeps CRDs in sync with the chart version automatically.
# ---------------------------------------------------------------------------
resource "helm_release" "cert_manager" {
  count = var.enable_cert_manager ? 1 : 0

  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  namespace  = kubernetes_namespace_v1.cert_manager[0].metadata[0].name
  version    = var.cert_manager_chart_version

  wait    = true
  atomic  = true
  timeout = 300

  values = [
    yamlencode({
      installCRDs = true
    })
  ]

  depends_on = [kubernetes_namespace_v1.cert_manager]
}

# ---------------------------------------------------------------------------
# ClusterIssuer: letsencrypt-prod
# Uses Cloudflare DNS-01 so certificates can be issued for non-HTTP
# workloads and wildcard domains. The email field is intentionally left
# empty — the operator must set it via the cloudflare_acme_email variable
# or by patching this manifest post-deploy.
#
# NOTE: kubernetes_manifest requires the cert-manager CRDs to be present.
# The depends_on on helm_release.cert_manager ensures CRDs are installed
# before this resource is applied.
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "letsencrypt_prod_cluster_issuer" {
  count = var.enable_cert_manager ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        server = "https://acme-v02.api.letsencrypt.org/directory"
        # Operator fills in their email address — left empty to avoid
        # committing a PII value into the module defaults.
        email = ""
        privateKeySecretRef = {
          name = "letsencrypt-prod"
        }
        solvers = [
          {
            dns01 = {
              cloudflare = {
                apiTokenSecretRef = {
                  name = kubernetes_secret_v1.cloudflare_api_token_cert_manager[0].metadata[0].name
                  key  = "api-token"
                }
              }
            }
          }
        ]
      }
    }
  }

  # cert-manager CRDs must be present (installed by the Helm release) before
  # the Kubernetes API will accept a ClusterIssuer resource.
  depends_on = [helm_release.cert_manager]
}
