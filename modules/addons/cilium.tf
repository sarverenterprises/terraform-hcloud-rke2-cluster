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
  timeout = 600

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
          clusterPoolIPv4PodCIDRList = [var.pod_cidr]
          clusterPoolIPv4MaskSize    = 24 # /24 per node = 254 pods/node
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
# Two implementations, selected by var.kubeconfig_path:
#
#   kubeconfig_path != null → null_resource + kubectl local-exec
#     Used on initial cluster deploy when CiliumClusterwideNetworkPolicy CRD
#     does not exist yet at plan time. The kubernetes_manifest provider
#     validates CRD kinds against the live API at plan time, causing
#     "API did not recognize GroupVersionKind" errors even when depends_on
#     is set. kubectl apply runs only at apply time, after helm_release.cilium
#     completes and the CRD is registered.
#
#   kubeconfig_path == null → kubernetes_manifest
#     Used on subsequent applies (or in workspaces where no kubeconfig file
#     exists on disk) once Cilium CRDs are already present in the cluster.
# ---------------------------------------------------------------------------

# kubectl-based apply: used when kubeconfig is on disk (initial deploy).
resource "null_resource" "block_metadata_api" {
  count = var.kubeconfig_path != null ? 1 : 0

  triggers = {
    # Re-apply if the Cilium release changes (upgrade or recreate).
    cilium_release_id = helm_release.cilium.id
  }

  provisioner "local-exec" {
    # Wait for the CRD to be established before applying — Helm marks the
    # release complete once pods are Ready, but CRD schema propagation through
    # the API aggregation layer can lag by a few seconds.
    #
    # kubectl wait --for=condition=established exits immediately with
    # "Error from server (NotFound)" if the resource does not exist yet — it
    # only waits on the condition of an already-present resource. Poll with
    # kubectl get until the CRD appears, then use wait --for=condition=established
    # to confirm it is fully registered.
    command     = <<-EOT
      echo "Waiting for CRD ciliumclusterwidenetworkpolicies.cilium.io to appear..."
      for i in $(seq 1 24); do
        kubectl --kubeconfig '${var.kubeconfig_path}' \
          get crd ciliumclusterwidenetworkpolicies.cilium.io \
          --ignore-not-found 2>/dev/null | grep -q ciliumclusterwidenetworkpolicies \
          && break
        echo "  attempt $i/24: CRD not found yet, retrying in 5s..."
        sleep 5
      done
      kubectl --kubeconfig '${var.kubeconfig_path}' \
        wait --for=condition=established \
        crd/ciliumclusterwidenetworkpolicies.cilium.io \
        --timeout=60s
      kubectl --kubeconfig '${var.kubeconfig_path}' apply -f - <<'POLICY'
      apiVersion: cilium.io/v2
      kind: CiliumClusterwideNetworkPolicy
      metadata:
        name: block-metadata-api
      spec:
        # Apply to non-system namespaces only.
        # kube-system pods (hcloud-csi, hcloud-ccm) legitimately need the
        # Hetzner metadata API to determine node location and instance ID.
        endpointSelector:
          matchExpressions:
          - key: io.kubernetes.pod.namespace
            operator: NotIn
            values: [kube-system, kube-public, kube-node-lease]
        # Explicitly allow all egress to all entities so only the deny
        # below takes effect. toEntities: ["all"] is required; egress: [{}]
        # is silently ignored by Cilium and still triggers default-deny mode.
        egress:
        - toEntities:
          - "all"
        egressDeny:
        - toCIDR:
          - 169.254.169.254/32
      POLICY
    EOT
    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [helm_release.cilium]
}

# kubernetes_manifest fallback: used on subsequent applies when CRD exists.
resource "kubernetes_manifest" "block_metadata_api" {
  count = var.kubeconfig_path == null ? 1 : 0

  manifest = {
    apiVersion = "cilium.io/v2"
    kind       = "CiliumClusterwideNetworkPolicy"
    metadata = {
      name = "block-metadata-api"
    }
    spec = {
      # Apply to non-system namespaces only.
      # kube-system pods (hcloud-csi, hcloud-ccm) legitimately need the
      # Hetzner metadata API to determine node location and instance ID.
      endpointSelector = {
        matchExpressions = [
          {
            key      = "io.kubernetes.pod.namespace"
            operator = "NotIn"
            values   = ["kube-system", "kube-public", "kube-node-lease"]
          }
        ]
      }
      # Explicitly allow all egress to all entities so only the deny
      # below takes effect. toEntities: ["all"] is required; egress: [{}]
      # is silently ignored by Cilium and still triggers default-deny mode.
      egress     = [{ toEntities = ["all"] }]
      egressDeny = [{ toCIDR = ["169.254.169.254/32"] }]
    }
  }

  depends_on = [helm_release.cilium]
}
