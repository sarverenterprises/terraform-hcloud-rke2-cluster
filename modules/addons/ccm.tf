# =============================================================================
# Hetzner Cloud Controller Manager (CCM)
#
# Manages Hetzner-specific Kubernetes resources: node addressing, load
# balancers, and private network routes. Must run before CSI because CSI
# depends on node labels CCM applies.
#
# Deployed only when var.enable_hcloud_ccm == true.
# =============================================================================

# ---------------------------------------------------------------------------
# Secret: hcloud credentials for CCM
# Token + private network name are passed via a Kubernetes Secret so they
# are never present in Helm values (which appear in plain-text in the
# release manifest stored in the cluster).
# ---------------------------------------------------------------------------
resource "kubernetes_secret_v1" "hcloud_ccm" {
  count = var.enable_hcloud_ccm ? 1 : 0

  metadata {
    name      = "hcloud"
    namespace = "kube-system"
  }

  data = {
    token   = var.hcloud_ccm_token
    network = var.private_network_name
  }
}

# ---------------------------------------------------------------------------
# Helm release: hcloud-ccm
# ---------------------------------------------------------------------------
resource "helm_release" "hcloud_ccm" {
  count = var.enable_hcloud_ccm ? 1 : 0

  name       = "hcloud-ccm"
  repository = "https://charts.hetzner.cloud"
  chart      = "hcloud-cloud-controller-manager"
  namespace  = "kube-system"
  version    = var.hcloud_ccm_chart_version

  wait    = true
  atomic  = true
  timeout = 300

  values = [
    yamlencode({
      networking = {
        enabled = true
        # Must match cluster-cidr in RKE2 server config and Cilium IPAM pool
        clusterCIDR = var.pod_cidr
      }
      env = {
        # Without a default location, CCM refuses to create LoadBalancer Services
        # unless every Service carries load-balancer.hetzner.cloud/location or
        # load-balancer.hetzner.cloud/network-zone annotations.
        HCLOUD_LOAD_BALANCERS_DEFAULT_LOCATION = {
          value = var.location
        }
      }
    })
  ]

  # Cilium must finish before CCM can deploy: CCM pods require cluster
  # networking to become Ready, and networking is provided by Cilium.
  #
  # IMPORTANT: CCM must NOT depend on wait_for_coredns. When hcloud CCM is
  # configured, the kubelet registers every new node with the taint
  # node.cloudprovider.kubernetes.io/uninitialized:NoSchedule. CCM removes
  # that taint once it initialises each node. The RKE2 helm-install-rke2-coredns
  # Job pod does NOT tolerate that taint, so CoreDNS can never schedule until
  # CCM runs. Making CCM depend on CoreDNS readiness creates an unresolvable
  # deadlock. CCM and wait_for_coredns must run in parallel after Cilium.
  depends_on = [kubernetes_secret_v1.hcloud_ccm[0], helm_release.cilium]
}
