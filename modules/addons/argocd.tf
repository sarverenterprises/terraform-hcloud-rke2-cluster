# =============================================================================
# Argo CD + Argo Rollouts
#
# Installs Argo CD (UI-driven GitOps controller) and Argo Rollouts (progressive
# delivery controller) as a bundled unit via Helm.
#
# Argo CD is configured with:
#   - Optional Dex SSO: GitHub OAuth auto-wire when argocd_github_client_id +
#     argocd_github_client_secret are provided; raw Dex YAML override via
#     argocd_dex_connectors for any other provider.
#   - Optional Traefik Ingress when argocd_hostname is set (same pattern as
#     grafana_hostname in monitoring.tf). A lifecycle precondition enforces
#     that enable_ingress = true when argocd_hostname is provided.
#   - server.insecure mode (via configs.params) so Traefik can proxy plain HTTP
#     to the argocd-server backend — Traefik terminates TLS externally.
#
# Argo Rollouts is installed cluster-wide (clusterInstall = true, default)
# so Rollout CRDs are available across all namespaces.
#
# This add-on is fully independent of Flux — both may be enabled simultaneously.
# No Application or ApplicationSet resources are created; initial app wiring
# is left to the operator.
#
# Deployed only when var.enable_argocd == true.
# =============================================================================

# ---------------------------------------------------------------------------
# Namespace: argocd
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "argocd" {
  count = var.enable_argocd ? 1 : 0

  metadata {
    name = "argocd"
  }
}

# ---------------------------------------------------------------------------
# Namespace: argo-rollouts
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "argo_rollouts" {
  count = var.enable_argocd ? 1 : 0

  metadata {
    name = "argo-rollouts"
  }
}

# ---------------------------------------------------------------------------
# Secret: argocd-secret (GitHub OAuth credentials)
#
# Argo CD's Dex connector config uses a $-sigil syntax to reference secrets:
#   clientSecret: $dex.github.clientSecret
# This sigil is resolved from a Kubernetes Secret named "argocd-secret" in
# the argocd namespace. The key name must match the sigil path exactly.
#
# Created only on the GitHub auto-wire path (not for raw argocd_dex_connectors
# override, where the operator manages their own secret keys).
#
# Note: "argocd-secret" is also Argo CD's own reserved secret name. If the
# chart also creates this secret on first install, the pre-existing secret
# takes precedence. Argo CD merges its own keys into the secret; the
# dex.github.clientSecret key added here will be preserved.
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "argocd_github_oauth" {
  count = (var.enable_argocd &&
    var.argocd_dex_connectors == null &&
    var.argocd_github_client_id != null &&
  var.argocd_github_client_secret != null) ? 1 : 0

  metadata {
    name      = "argocd-secret"
    namespace = kubernetes_namespace_v1.argocd[0].metadata[0].name
  }

  data = {
    # Key name must exactly match the $sigil used in dex.config below.
    "dex.github.clientSecret" = var.argocd_github_client_secret
  }

  depends_on = [kubernetes_namespace_v1.argocd]
}

# ---------------------------------------------------------------------------
# Locals: Dex config and global domain
#
# Precedence: raw argocd_dex_connectors override > GitHub auto-wire > null
#
# The dex.config ConfigMap value is a raw YAML string — not a nested object.
# Use a heredoc for the GitHub auto-wire path so that the $dex.github.clientSecret
# sigil is preserved as a literal string (not interpolated by Terraform).
# ---------------------------------------------------------------------------
locals {
  argocd_dex_config_yaml = (
    var.argocd_dex_connectors != null
    ? var.argocd_dex_connectors
    : (var.argocd_github_client_id != null && var.argocd_github_client_secret != null)
    ? <<-EOT
      connectors:
      - type: github
        id: github
        name: GitHub
        config:
          clientID: ${var.argocd_github_client_id}
          clientSecret: $dex.github.clientSecret
      EOT
    : null
  )

  # Used in global.domain so Argo CD builds correct Dex OAuth redirect URIs.
  argocd_global_domain = var.argocd_hostname != null ? var.argocd_hostname : ""
}

# ---------------------------------------------------------------------------
# Helm release: argo-cd
#
# timeout = 600: CRDs + many Deployments (server, repo-server, application-
# controller, dex, redis) routinely take 3–6 minutes on a fresh cluster.
#
# configs.params."server.insecure" = "true": required when Traefik terminates
# TLS upstream — argocd-server must accept plain HTTP from the proxy. This
# replaces the deprecated server.extraArgs = ["--insecure"] pattern.
#
# lifecycle.precondition: prevents plans where argocd_hostname is set but
# enable_ingress = false (Traefik must exist to create the Ingress).
# ---------------------------------------------------------------------------
resource "helm_release" "argocd" {
  count = var.enable_argocd ? 1 : 0

  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace_v1.argocd[0].metadata[0].name
  version    = var.argocd_chart_version

  wait    = true
  atomic  = true
  timeout = 600

  lifecycle {
    precondition {
      condition     = !(var.argocd_hostname != null && !var.enable_ingress)
      error_message = "argocd_hostname requires enable_ingress = true. Traefik must be deployed before an Argo CD Ingress can be created."
    }
  }

  values = [
    yamlencode(merge(
      {
        global = {
          # Sets the Argo CD external URL — required for Dex OAuth redirect URIs.
          domain = local.argocd_global_domain
        }

        crds = {
          install = true
          keep    = true
        }

        configs = merge(
          {
            params = {
              # String "true", not bool — chart renders this into an argocd-cmd-params-cm
              # ConfigMap where all values are strings.
              "server.insecure" = "true"
            }
          },
          # Inject dex.config only when SSO is configured.
          local.argocd_dex_config_yaml != null ? {
            cm = {
              "dex.config" = local.argocd_dex_config_yaml
            }
          } : {}
        )

        dex = {
          # Enable Dex sidecar only when SSO is configured.
          enabled = local.argocd_dex_config_yaml != null
        }
      },
      # Ingress block — injected only when argocd_hostname is set.
      var.argocd_hostname != null ? {
        server = {
          ingress = {
            enabled          = true
            ingressClassName = "traefik"
            # chart v7+/v9.x: hostname (singular), not hosts (list)
            hostname = var.argocd_hostname
            # Traefik handles TLS; argocd-server receives plain HTTP.
            tls = false
          }
        }
      } : {}
    ))
  ]

  depends_on = [
    kubernetes_namespace_v1.argocd,
    kubernetes_secret_v1.argocd_github_oauth,
  ]
}

# ---------------------------------------------------------------------------
# Helm release: argo-rollouts
#
# Installs Argo Rollouts controller and CRDs (Rollout, AnalysisRun,
# AnalysisTemplate, Experiment, ClusterAnalysisTemplate).
#
# clusterInstall = true (default): watches Rollout resources in all namespaces.
#
# Note: argo-rollouts CRD keys are top-level (installCRDs, keepCRDs) — not
# nested under a crds: block as in the argo-cd chart.
# ---------------------------------------------------------------------------
resource "helm_release" "argo_rollouts" {
  count = var.enable_argocd ? 1 : 0

  name       = "argo-rollouts"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-rollouts"
  namespace  = kubernetes_namespace_v1.argo_rollouts[0].metadata[0].name
  version    = var.argo_rollouts_chart_version

  wait    = true
  atomic  = true
  timeout = 300

  values = [
    yamlencode({
      # Top-level CRD flags — differ from argo-cd chart schema.
      installCRDs = true
      keepCRDs    = true
      # clusterInstall defaults to true — controller watches all namespaces.
      # dashboard defaults to disabled — operator enables post-install if needed.
    })
  ]

  depends_on = [kubernetes_namespace_v1.argo_rollouts]
}
