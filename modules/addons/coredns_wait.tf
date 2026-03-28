# =============================================================================
# CoreDNS Readiness Gate
#
# Waits for CoreDNS to become Ready after Cilium has deployed, and
# automatically recovers stuck helm-install-rke2-coredns installer pods.
#
# Problem: RKE2's internal HelmChart controller deploys CoreDNS via a Job.
# The Job pod (helm-install-rke2-coredns-*) can get stuck in ContainerCreating
# if the kubelet is under backpressure during cluster bootstrap. This prevents
# CoreDNS from deploying, which in turn causes hcloud-csi-controller to
# crash-loop (it resolves api.hetzner.cloud by hostname and exits with code 2
# when DNS is unavailable).
#
# Fix: Poll for CoreDNS readiness. After a 2-minute grace period, force-delete
# any stuck installer pods. The Job controller immediately creates a new pod
# which starts successfully once the cluster stabilises.
#
# CCM and CSI depend on this resource so they only deploy after DNS is
# available, eliminating the CSI crash-loop-until-CoreDNS sequence.
#
# When kubeconfig_path is null (subsequent applies, cluster already running),
# CoreDNS is already up — this resource is a no-op.
# =============================================================================

resource "null_resource" "wait_for_coredns" {
  triggers = {
    # Re-run whenever Cilium changes — CoreDNS may need a fresh start.
    cilium_release_id = helm_release.cilium.id
  }

  provisioner "local-exec" {
    command     = <<-EOT
      KUBECONFIG_PATH='${var.kubeconfig_path != null ? var.kubeconfig_path : ""}'

      if [ -z "$KUBECONFIG_PATH" ]; then
        echo "No kubeconfig_path set — CoreDNS wait skipped (subsequent apply, DNS already running)"
        exit 0
      fi

      echo "Waiting for CoreDNS to become ready..."
      MAX_WAIT=600
      POLL_INTERVAL=10
      ELAPSED=0

      while [ "$ELAPSED" -lt "$MAX_WAIT" ]; do
        # kubectl wait exits 0 as soon as at least one kube-dns pod is Ready.
        # Exits non-zero (and quickly) if no pods match yet — which is correct;
        # we just keep looping.
        if kubectl --kubeconfig "$KUBECONFIG_PATH" \
          wait pods -n kube-system -l k8s-app=kube-dns \
          --for=condition=Ready --timeout=5s 2>/dev/null; then
          echo "CoreDNS is ready ($${ELAPSED}s elapsed)"
          # Uncordon any CP nodes that were cordoned by this script during recovery
          CORDONED_CPS=$(kubectl --kubeconfig "$KUBECONFIG_PATH" \
            get nodes -l node-role.kubernetes.io/control-plane=true \
            --no-headers --request-timeout=15s 2>/dev/null \
            | awk '/SchedulingDisabled/ {print $1}' || true)
          if [ -n "$CORDONED_CPS" ]; then
            echo "$CORDONED_CPS" | while IFS= read -r NODE; do
              [ -n "$NODE" ] || continue
              echo "  Uncordoning CP node: $NODE"
              kubectl --kubeconfig "$KUBECONFIG_PATH" uncordon "$NODE" \
                --request-timeout=15s 2>/dev/null || true
            done
          fi
          exit 0
        fi

        # After a 2-minute grace period, check for stuck installer pods.
        # A normally-progressing helm-install-rke2-coredns pod finishes in < 60s.
        # Anything still Pending/ContainerCreating/Error after 120s is stuck —
        # force-delete it so the Job controller spawns a fresh replacement.
        if [ "$ELAPSED" -ge 120 ]; then
          STUCK=$(kubectl --kubeconfig "$KUBECONFIG_PATH" \
            get pods -n kube-system --no-headers --request-timeout=15s 2>/dev/null \
            | awk '/helm-install-rke2-coredns/ && !/Succeeded/ && !/Running/ {print $1}')
          if [ -n "$STUCK" ]; then
            echo "  Stuck CoreDNS installer pod(s) detected — force-deleting: $STUCK"
            # R2: Cordon NotReady/Unknown CP nodes (single query, not per-pod lookup)
            NOTREADY_CPS=$(kubectl --kubeconfig "$KUBECONFIG_PATH" \
              get nodes -l node-role.kubernetes.io/control-plane=true \
              --no-headers --request-timeout=15s 2>/dev/null \
              | awk '$2 == "False" || $2 == "Unknown" {print $1}' || true)
            if [ -n "$NOTREADY_CPS" ]; then
              echo "$NOTREADY_CPS" | while IFS= read -r NODE; do
                [ -n "$NODE" ] || continue
                echo "  Cordoning NotReady/Unknown CP node: $NODE"
                kubectl --kubeconfig "$KUBECONFIG_PATH" cordon "$NODE" \
                  --request-timeout=15s 2>/dev/null || true
              done
            fi
            echo "$STUCK" | xargs -I{} kubectl --kubeconfig "$KUBECONFIG_PATH" \
              delete pod {} -n kube-system --force --grace-period=0 2>/dev/null || true
          fi
        fi

        # R3: Reset Job backoff at 300s by deleting and letting HelmChart controller recreate
        if [ "$ELAPSED" -eq 300 ]; then
          echo "  $${ELAPSED}s elapsed: deleting CoreDNS installer Job to reset backoff counter"
          kubectl --kubeconfig "$KUBECONFIG_PATH" delete job helm-install-rke2-coredns \
            -n kube-system --ignore-not-found=true --request-timeout=15s 2>/dev/null || true
        fi

        echo "  $${ELAPSED}s elapsed: CoreDNS not ready yet, retrying in $${POLL_INTERVAL}s..."
        sleep "$POLL_INTERVAL"
        ELAPSED=$(( ELAPSED + POLL_INTERVAL ))
      done

      echo "ERROR: CoreDNS did not become ready after $${MAX_WAIT}s" >&2
      exit 1
    EOT
    interpreter = ["/bin/bash", "-c"]
  }

  depends_on = [helm_release.cilium]
}
