# =============================================================================
# Cilium CNI
#
# Cilium is deployed unconditionally — a CNI is always required for the
# cluster to function. RKE2 is configured with `cni: none` so that the
# default Canal is disabled; Cilium takes its place via this Helm release.
#
# Key design constraints:
#   - routingMode/tunnelProtocol replaces the deprecated `tunnel` key (≥1.14)
#   - kubeProxyReplacement must be the string "false" (not bool) for hcloud-ccm
#     compatibility; full kube-proxy replacement causes CCM LB reconciliation
#     failures (rancher/rke2#4862)
#   - MTU 1450 = 1500 (Hetzner NIC) − 50 (VXLAN overhead); set explicitly to
#     avoid auto-detection picking the wrong interface in multi-NIC nodes
#   - operator.replicas = 2 for HA; a single operator is a SPOF for IPAM
# =============================================================================

# ---------------------------------------------------------------------------
# Helm release: cilium
# ---------------------------------------------------------------------------
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  namespace  = "kube-system"
  version    = var.cilium_chart_version

  wait    = true
  atomic  = true
  timeout = 300

  values = [
    yamlencode({
      # Routing — current field names (tunnel/tunnelProtocol deprecated pre-1.14)
      routingMode    = "tunnel"
      tunnelProtocol = "vxlan"

      # MTU: Hetzner private network caps at 1450 bytes. Subtract 50 bytes
      # of VXLAN encapsulation overhead (8 VXLAN + 20 outer IP + 8 UDP + 14 Ethernet)
      # = 1400 bytes pod MTU. Setting explicitly prevents auto-detection from
      # picking the wrong interface (public eth0 vs private eth1) on multi-NIC nodes.
      MTU = 1400

      # IPAM: cluster-pool mode has Cilium Operator manage the address space directly,
      # with no dependency on kube-controller-manager's --allocate-node-cidrs.
      # More Cilium-native than "kubernetes" mode and easier to reason about.
      ipam = {
        mode = "cluster-pool"
        operator = {
          clusterPoolIPv4PodCIDRList = ["10.42.0.0/16"]  # Match RKE2 default cluster-cidr
          clusterPoolIPv4MaskSize    = 24                 # /24 per node = 254 pods/node
        }
      }

      # Must be a string "false", not bool — Helm coerces bools to "true"/"false"
      # which then fails string comparisons in the Cilium agent startup code.
      # Full kube-proxy replacement breaks hcloud-ccm LoadBalancer reconciliation.
      kubeProxyReplacement = "false"

      # Use localhost (RKE2's local proxy) instead of the LB IP.
      # RKE2 runs a local load-balancing proxy on every node at localhost:6443
      # that forwards to real API server endpoints. This avoids a bootstrap
      # race where the external LB health check hasn't passed yet during first boot.
      k8sServiceHost = "localhost"
      k8sServicePort = "6443"

      operator = {
        # 2 replicas for HA — leader election handles active/standby.
        # A single replica means one node failure stalls IPAM for new pods.
        replicas = 2
      }
    })
  ]
}

# ---------------------------------------------------------------------------
# CiliumClusterwideNetworkPolicy: block metadata API egress
#
# The Hetzner metadata API (169.254.169.254) is reachable from all pods by
# default. This policy denies egress to it cluster-wide, preventing workloads
# from leaking credentials or enumerating instance metadata.
#
# Applied after Cilium is ready so the CRD exists when this resource is created.
# ---------------------------------------------------------------------------
resource "kubernetes_manifest" "block_metadata_api" {
  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumClusterwideNetworkPolicy"
    metadata = {
      name = "block-metadata-api"
    }
    spec = {
      # Empty selector — applies to all endpoints in the cluster
      endpointSelector = {}
      egressDeny = [
        {
          toCIDR = ["169.254.169.254/32"]
        }
      ]
    }
  }

  depends_on = [helm_release.cilium]
}
