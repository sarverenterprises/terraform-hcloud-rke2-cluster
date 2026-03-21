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
