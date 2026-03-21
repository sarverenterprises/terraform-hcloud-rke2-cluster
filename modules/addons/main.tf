# =============================================================================
# Add-ons Module
#
# Deploys Kubernetes add-ons via Helm after the cluster is ready.
# Each component is behind a feature flag and implemented in its own file:
#
#   ccm.tf              — Hetzner Cloud Controller Manager
#   csi.tf              — Hetzner CSI driver
#   cilium.tf           — Cilium CNI
#   external_dns.tf     — External-DNS (two Cloudflare deployments)
#   cert_manager.tf     — cert-manager + Cloudflare ClusterIssuer
#   ingress.tf          — Traefik (+ Gateway API CRDs) or NGINX
#   longhorn.tf         — Longhorn distributed storage
#   autoscaler.tf       — Cluster Autoscaler (HCLOUD_CLUSTER_CONFIG)
#   flux.tf             — Flux CD bootstrap
#   monitoring.tf       — kube-prometheus-stack
#   tailscale.tf        — Tailscale Kubernetes operator
#
# IMPORTANT: This module requires Helm and Kubernetes providers to be configured
# in the calling root module (see examples/) using the fetched kubeconfig.
# It will not function on a first-apply before the cluster exists.
# =============================================================================
