# Outputs are added in individual component files (ccm.tf, csi.tf, etc.)
# as each add-on is implemented.

# ---------------------------------------------------------------------------
# Flux
# ---------------------------------------------------------------------------

output "flux_public_key" {
  description = "Flux SSH deploy key public key. Register as a read-only deploy key on the GitHub repo."
  value       = var.enable_flux ? tls_private_key.flux[0].public_key_openssh : null
  sensitive   = false
}

# ---------------------------------------------------------------------------
# Argo CD
# ---------------------------------------------------------------------------

output "grafana_admin_password" {
  description = "Auto-generated Grafana admin password. Only set when enable_monitoring=true."
  value       = var.enable_monitoring ? random_password.grafana_admin[0].result : null
  sensitive   = true
}

output "argocd_admin_password_hint" {
  description = <<-EOT
    Argo CD generates an initial admin password on first install and stores it in
    a Kubernetes Secret. Retrieve it after apply with:

      kubectl -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' | base64 -d

    This secret is automatically deleted once the admin password is changed via
    the Argo CD UI or CLI (argocd account update-password).
  EOT
  value       = var.enable_argocd ? "See output description for kubectl retrieval command." : null
}
