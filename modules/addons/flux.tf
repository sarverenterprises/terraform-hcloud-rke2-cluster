# =============================================================================
# Flux CD Bootstrap
#
# Installs Flux v2 via the fluxcd-community OCI Helm chart and provisions:
#   - A TLS keypair (RSA-4096) for Flux's Git SSH authentication
#   - The flux-system namespace
#   - A kubernetes secret carrying the SSH identity so the Flux source-controller
#     can clone the GitOps repository
#
# The generated public key must be registered as a read-only deploy key on the
# target GitHub repository. Registration can be automated (flux_deploy_key_mode
# == "auto" with a valid github_token) or handled manually by the operator.
#
# Deployed only when var.enable_flux == true.
# =============================================================================

# ---------------------------------------------------------------------------
# SSH Keypair
#
# RSA 4096 is used over ECDSA for maximum compatibility with GitHub deploy
# keys and older Git SSH implementations that may not support ed25519.
# ---------------------------------------------------------------------------
resource "tls_private_key" "flux" {
  count = var.enable_flux ? 1 : 0

  algorithm = "RSA"
  rsa_bits  = 4096
}

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "flux_system" {
  count = var.enable_flux ? 1 : 0

  metadata {
    name = "flux-system"
  }
}

# ---------------------------------------------------------------------------
# Secret: flux-system
#
# Carries the SSH identity for Flux's source-controller. The known_hosts
# field is intentionally left empty — the operator must populate it with the
# target repository host's SSH fingerprint (e.g. via `flux create secret git`
# or by patching the secret post-bootstrap). Providing it empty here avoids
# a chicken-and-egg problem where the secret must exist before the
# GitRepository resource is created.
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "flux_system" {
  count = var.enable_flux ? 1 : 0

  metadata {
    name      = "flux-system"
    namespace = kubernetes_namespace_v1.flux_system[0].metadata[0].name
  }

  data = {
    "identity"     = tls_private_key.flux[0].private_key_pem
    "identity.pub" = tls_private_key.flux[0].public_key_openssh
    # Operator registers host fingerprint after bootstrap.
    "known_hosts" = ""
  }

  depends_on = [kubernetes_namespace_v1.flux_system]
}

# ---------------------------------------------------------------------------
# Helm release: flux2
#
# Uses the fluxcd-community OCI registry chart so the chart is fetched from
# ghcr.io rather than a traditional Helm repository index. The repository
# field is left blank for OCI charts; the chart path includes the full
# registry reference.
# ---------------------------------------------------------------------------
resource "helm_release" "flux2" {
  count = var.enable_flux ? 1 : 0

  name       = "flux2"
  repository = "oci://ghcr.io/fluxcd-community/charts"
  chart      = "flux2"
  namespace  = kubernetes_namespace_v1.flux_system[0].metadata[0].name
  version    = var.flux_version

  wait    = true
  atomic  = true
  timeout = 300

  values = [
    yamlencode({
      clusterDomain = "cluster.local"
    })
  ]

  depends_on = [kubernetes_secret_v1.flux_system]
}

# ---------------------------------------------------------------------------
# Auto-register GitHub deploy key
#
# When flux_deploy_key_mode == "auto" and a github_token is provided, the
# generated public key is registered on the configured GitHub repository via
# the GitHub REST API. This eliminates the manual step of copying the public
# key from the Terraform output and pasting it into GitHub Settings.
#
# The deploy key is created read-only — Flux only needs pull access.
#
# Gated by three conditions:
#   1. enable_flux == true
#   2. flux_deploy_key_mode == "auto"
#   3. github_token is not null (a PAT with repo write scope is required)
# ---------------------------------------------------------------------------
resource "null_resource" "flux_github_deploy_key" {
  count = (var.enable_flux && var.flux_deploy_key_mode == "auto" && var.github_token != null) ? 1 : 0

  triggers = {
    # Re-register when the public key or the target repo changes.
    public_key = tls_private_key.flux[0].public_key_openssh
    org        = var.flux_github_org
    repo       = var.flux_github_repo
  }

  provisioner "local-exec" {
    command = <<-EOT
      curl -fsSL \
        -X POST \
        -H "Authorization: token ${var.github_token}" \
        -H "Content-Type: application/json" \
        https://api.github.com/repos/${var.flux_github_org}/${var.flux_github_repo}/keys \
        -d '{"title":"flux-${var.cluster_name}","key":"${trimspace(tls_private_key.flux[0].public_key_openssh)}","read_only":true}'
    EOT
  }

  depends_on = [helm_release.flux2]
}
