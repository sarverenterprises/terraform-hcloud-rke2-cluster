# =============================================================================
# Tailscale Kubernetes Operator
#
# Installs the Tailscale Kubernetes Operator via the official Helm chart.
# The operator enables Tailscale-based ingress/egress for Services and exposes
# Kubernetes services onto the tailnet without a traditional ingress controller.
#
# Authentication uses an OAuth client secret stored in a Kubernetes Secret.
# The secret is pre-created before the Helm release so the operator can read
# its credentials on first startup. The operator hostname on the tailnet is
# set to "<cluster_name>-operator" to avoid naming collisions when multiple
# clusters share the same tailnet.
#
# Deployed only when var.enable_tailscale_operator == true.
# =============================================================================

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------
resource "kubernetes_namespace_v1" "tailscale" {
  count = var.enable_tailscale_operator ? 1 : 0

  metadata {
    name = "tailscale"
  }
}

# ---------------------------------------------------------------------------
# Secret: operator-oauth
#
# The Tailscale operator reads OAuth credentials from this secret.
# client_id is left empty here — the operator should be configured with an
# OAuth client (not an auth key). For auth-key-based bootstrapping, set
# client_secret to var.tailscale_operator_auth_key. The operator chart will
# use whichever credential is populated at install time.
#
# Operator fills in client_id via their OAuth app registration in the
# Tailscale admin console; client_secret carries the auth key or OAuth secret.
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "tailscale_operator_oauth" {
  count = var.enable_tailscale_operator ? 1 : 0

  metadata {
    name      = "operator-oauth"
    namespace = kubernetes_namespace_v1.tailscale[0].metadata[0].name
  }

  data = {
    client_id     = ""
    client_secret = var.tailscale_operator_auth_key != null ? var.tailscale_operator_auth_key : ""
  }

  depends_on = [kubernetes_namespace_v1.tailscale]
}

# ---------------------------------------------------------------------------
# Helm release: tailscale-operator
# ---------------------------------------------------------------------------
resource "helm_release" "tailscale_operator" {
  count = var.enable_tailscale_operator ? 1 : 0

  name       = "tailscale-operator"
  repository = "https://pkgs.tailscale.com/helmcharts"
  chart      = "tailscale-operator"
  namespace  = kubernetes_namespace_v1.tailscale[0].metadata[0].name
  version    = "~> 1.76"

  wait    = true
  atomic  = true
  timeout = 300

  values = [
    yamlencode({
      oauth = {
        # Credentials are sourced from the operator-oauth secret pre-created
        # above. Setting these to empty strings here defers authentication to
        # the secret; the operator will read its credentials from the secret
        # rather than from chart values (which would be visible in Helm state).
        clientId     = ""
        clientSecret = ""
      }
      operatorConfig = {
        # Unique hostname on the tailnet — avoids collisions when multiple
        # clusters share the same tailnet account.
        hostname = "${var.cluster_name}-operator"
      }
    })
  ]

  depends_on = [kubernetes_secret_v1.tailscale_operator_oauth]
}
