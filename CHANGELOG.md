# Changelog

## [0.4.19] — 2026-03-23

### Fixed

- **R1 (etcd orphan recovery):** `rke2-etcd-recovery.sh` now clears the etcd member directory (`/var/lib/rancher/rke2/server/db/etcd/member`) when an orphaned etcd process is killed. Without this, rke2-server would fail to reconnect to the stale member state on restart, causing indefinite TLS handshake failures after a hard crash.
- **R2 (CP node cordon):** `wait_for_coredns` now cordons NotReady/Unknown control-plane nodes that have stuck CoreDNS installer pods assigned to them. Uses a single label-selector query (`-l node-role.kubernetes.io/control-plane=true`) rather than a per-pod lookup, preventing the scheduler from continuing to target broken nodes. **Note: cordon is intentional and persistent — if a CP node recovers, run `kubectl uncordon <node>` manually.**
- **R3 (Job backoff reset):** `wait_for_coredns` now deletes the `helm-install-rke2-coredns` Job at exactly 300s elapsed to reset its exponential backoff counter, preventing timeout when mass force-deletes have exhausted the Job's failure threshold.

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
