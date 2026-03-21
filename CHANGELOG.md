# Changelog

## [0.1.0] — 2026-03-21

### Added
- Initial release of terraform-hcloud-rke2-cluster module
- RKE2 HA control plane (3 nodes) with embedded etcd
- Hetzner Cloud Controller Manager and CSI driver
- Cilium CNI with VXLAN tunnel mode
- External-DNS with dual Cloudflare deployments (proxied + DNS-only)
- cert-manager with Cloudflare DNS-01 ClusterIssuer
- Traefik and NGINX ingress options with Gateway API CRDs
- Longhorn distributed storage with RWO and RWX StorageClasses
- Cluster Autoscaler with HCLOUD_CLUSTER_CONFIG multi-pool support
- Flux CD bootstrap with auto GitHub deploy key registration
- kube-prometheus-stack monitoring
- Tailscale Kubernetes operator and node-level enrollment
- Two-phase apply pattern for clean separation of infra and add-ons
