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
    # GitHub SSH host keys (from https://api.github.com/meta)
    "known_hosts" = "github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\ngithub.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=\ngithub.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk="
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
    environment = {
      GITHUB_TOKEN = var.github_token
    }
    command = <<-EOT
      # Check if key already exists (idempotency guard for re-applies)
      EXISTING=$(curl -fsSL \
        --connect-timeout 10 --max-time 30 \
        -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/repos/${var.flux_github_org}/${var.flux_github_repo}/keys" \
        | grep -c "${trimspace(tls_private_key.flux[0].public_key_openssh)}" 2>/dev/null || true)
      if [ "$EXISTING" -gt 0 ]; then
        echo "Deploy key already registered — skipping"
        exit 0
      fi
      curl -fsSL \
        --connect-timeout 10 --max-time 30 \
        -X POST \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Content-Type: application/json" \
        "https://api.github.com/repos/${var.flux_github_org}/${var.flux_github_repo}/keys" \
        -d '{"title":"flux-${var.cluster_name}","key":"${trimspace(tls_private_key.flux[0].public_key_openssh)}","read_only":true}'
    EOT
  }

  depends_on = [helm_release.flux2]
}
