#cloud-config
# RKE2 Control Plane bootstrap
# cluster_init=${cluster_init} — true for first node (initializes cluster), false for joiners

write_files:
  # ---------------------------------------------------------------------------
  # etcd orphan-recovery script
  #
  # If rke2-server crashes mid-run, etcd (its subprocess) keeps running as an
  # orphan with stale member state. On the next rke2-server start, the two
  # processes cannot reconnect — etcd rejects rke2-server's TLS handshake
  # indefinitely. This ExecStartPre script detects that condition and clears it.
  #
  # Safety: the script only acts when etcd is running WITHOUT rke2-server (the
  # crash scenario). In a normal graceful stop, rke2-server also stops etcd, so
  # pgrep finds nothing and the script is a no-op.
  # ---------------------------------------------------------------------------
  - path: /usr/local/bin/rke2-etcd-recovery.sh
    owner: root:root
    permissions: '0755'
    content: |
      #!/bin/bash
      # Match etcd by its config-file argument, which is stable across versions.
      # (The process name shown in ps may be just "etcd" without the full path
      #  since Go programs often show only the binary basename in argv[0].)
      MEMBER_DIR="/var/lib/rancher/rke2/server/db/etcd/member"
      ETCD_PID=$(pgrep -f "etcd --config-file=/var/lib/rancher/rke2" 2>/dev/null || true)
      if [ -n "$ETCD_PID" ]; then
        echo "rke2-etcd-recovery: orphaned etcd (PID $ETCD_PID) detected — killing"
        kill -9 "$ETCD_PID" 2>/dev/null || true
        sleep 2
        if [ -d "$MEMBER_DIR" ]; then
          rm -rf "$MEMBER_DIR" \
            && echo "rke2-etcd-recovery: member dir cleared — etcd will reinitialize as single-node" \
            || echo "rke2-etcd-recovery: WARNING — could not remove member dir"
        else
          echo "rke2-etcd-recovery: member dir absent — nothing to clear"
        fi
        echo "rke2-etcd-recovery: done — rke2-server will restart etcd cleanly"
      fi

  - path: /etc/systemd/system/rke2-server.service.d/10-etcd-recovery.conf
    owner: root:root
    permissions: '0644'
    content: |
      [Service]
      ExecStartPre=/usr/local/bin/rke2-etcd-recovery.sh

  - path: /etc/rancher/rke2/config.yaml
    owner: root:root
    permissions: '0600'
    content: |
%{ if !cluster_init ~}
      server: https://${first_cp_ip}:9345
%{ endif ~}
      token: "${rke2_token}"
      cloud-provider-name: external
      cni: none
      secrets-encryption: true
      cluster-cidr: "${pod_cidr}"
      service-cidr: "${service_cidr}"
%{ if enable_etcd_backup ~}
      etcd-snapshot-schedule-cron: "${etcd_snapshot_schedule_cron}"
      etcd-snapshot-retention: ${etcd_snapshot_retention}
      etcd-s3: true
      etcd-s3-endpoint: "${etcd_s3_endpoint}"
      etcd-s3-bucket: "${etcd_s3_bucket}"
      etcd-s3-region: "${etcd_s3_region}"
      etcd-s3-access-key: "${etcd_s3_access_key}"
      etcd-s3-secret-key: "${etcd_s3_secret_key}"
      etcd-s3-folder: "${etcd_s3_folder}"
%{ endif ~}
%{ if node_ip != null ~}
      node-ip: "${node_ip}"
%{ endif ~}
      tls-san:
        - "${control_plane_lb_ip}"
%{ if node_ip != null ~}
        - "${node_ip}"
%{ endif ~}
%{ if has_labels ~}
      node-label:
${label_args}
%{ endif ~}
%{ if has_taints ~}
      node-taint:
${taint_args}
%{ endif ~}

runcmd:
  # Block metadata API at host level before any services start (defense-in-depth).
  # Cilium network policy provides pod-level blocking after CNI deploys, but this
  # iptables rule covers the bootstrap window when Cilium is not yet running.
  # Root (uid 0) is exempted so cloud-init and CCM can still function.
  - iptables -I OUTPUT -d 169.254.169.254 -m owner ! --uid-owner 0 -j DROP

%{ if enable_tailscale && cluster_init ~}
  # Install Tailscale BEFORE RKE2 so its IP is available for tls-san.
  # cp-0 advertises cluster_subnet_cidr as a subnet route so tailnet peers
  # can reach the cluster's private network without public API exposure.
  - |
    for attempt in 1 2 3; do
      curl -fsSL https://tailscale.com/install.sh | sh && break
      echo "Tailscale install attempt $attempt failed — retrying in $((attempt * 10))s..." >&2
      sleep $((attempt * 10))
    done
    tailscale up \
      --auth-key="${tailscale_auth_key}" \
      --hostname="${hostname}" \
      --advertise-routes="${cluster_subnet_cidr}" \
      --accept-routes \
      2>&1 | tee -a /var/log/tailscale-setup.log
    if ! tailscale status >/dev/null 2>&1; then
      echo "ERROR: Tailscale enrollment failed — node will not be reachable via tailnet" >&2
    fi
    TS_IP=$(tailscale ip -4 2>/dev/null || true)
    if [ -n "$TS_IP" ]; then
      sed -i '/^tls-san:$/a\  - "'"$TS_IP"'"' /etc/rancher/rke2/config.yaml
    fi
%{ endif ~}

%{ if !cluster_init ~}
  # Follower CP: detect private network IP and write node-ip + tls-san entry
  # BEFORE RKE2 starts so etcd uses the private IP from the very first boot.
  #
  # Uses subnet prefix matching against cluster_subnet_cidr (e.g. 10.12.0.0/16
  # → prefix "10.12") to find the private IP regardless of interface name.
  # Retries for up to 60 s to handle DHCP assignment lag on cloud-init startup.
  - |
    SUBNET_PREFIX=$(echo "${cluster_subnet_cidr}" | cut -d/ -f1 | cut -d. -f1-2)
    PRIVATE_IP=""
    for i in $(seq 1 60); do
      PRIVATE_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+(?=/)' \
                   | grep "^$SUBNET_PREFIX\." | head -1 || true)
      if [ -n "$PRIVATE_IP" ]; then break; fi
      sleep 1
    done
    if [ -n "$PRIVATE_IP" ]; then
      printf '\nnode-ip: "%s"\n' "$PRIVATE_IP" >> /etc/rancher/rke2/config.yaml
      sed -i '/^tls-san:$/a\  - "'"$PRIVATE_IP"'"' /etc/rancher/rke2/config.yaml
      echo "Detected private IP: $PRIVATE_IP — written to config.yaml"
    else
      echo "FATAL: no private network IP detected after 60s — aborting to prevent wrong-IP join" >&2
      exit 1
    fi

%{ endif ~}

  # Install RKE2 server (retry up to 5 times for transient network failures)
  - |
    set -e
    for attempt in 1 2 3 4 5; do
      if curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="${rke2_version}" INSTALL_RKE2_TYPE="server" sh -; then
        break
      fi
      if [ "$attempt" -eq 5 ]; then
        echo "FATAL: RKE2 server install failed after 5 attempts" >&2
        exit 1
      fi
      echo "RKE2 install attempt $attempt failed — retrying in $((attempt * 15))s..." >&2
      sleep $((attempt * 15))
    done

  # Create required directories
  - mkdir -p /var/lib/rancher/rke2/server/manifests/

  # Reload systemd so the etcd-recovery drop-in is picked up before starting.
  - systemctl daemon-reload

  # Enable RKE2 server service (always — needed for next-boot start on all CP nodes).
  # CP joiners (CP-1/CP-2) are started by a Terraform provisioner after CP-0 is confirmed
  # healthy, not here — this prevents the split-brain race where a joiner starts rke2-server
  # before CP-0's etcd is ready to accept new members.
  - systemctl enable rke2-server.service
%{ if cluster_init ~}
  - systemctl start rke2-server.service
%{ endif ~}

%{ if cluster_init ~}
  # Wait for RKE2 server to be running and kubeconfig to be available.
  # Only needed on CP-0 (cluster-init node) — joiners are started by a Terraform
  # provisioner after CP-0 is healthy, so no cloud-init wait is required for them.
  - |
    timeout 300 bash -c '
      while ! systemctl is-active rke2-server --quiet 2>/dev/null; do
        echo "Waiting for rke2-server to start..."
        sleep 10
      done
      while [ ! -f /etc/rancher/rke2/rke2.yaml ]; do
        echo "Waiting for kubeconfig..."
        sleep 5
      done
    '
%{ endif ~}

  # Add RKE2 binaries to PATH for interactive sessions
  - |
    echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >> /root/.bashrc
    echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> /root/.bashrc
    ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl 2>/dev/null || true

%{ if enable_tailscale && !cluster_init ~}
  # Install Tailscale on follower CP nodes AFTER RKE2 starts.
  # Joiners do NOT accept-routes — they are already on the Hetzner private network and
  # accepting the cluster subnet route (advertised by cp-0) would cause etcd peer traffic
  # to be routed via Tailscale with source 100.x.x.x, which is not in the peer TLS cert
  # SANs, causing CP-0's etcd to reject the connection with EOF.
  - |
    for attempt in 1 2 3; do
      curl -fsSL https://tailscale.com/install.sh | sh && break
      echo "Tailscale install attempt $attempt failed — retrying in $((attempt * 10))s..." >&2
      sleep $((attempt * 10))
    done
    tailscale up \
      --auth-key="${tailscale_auth_key}" \
      --hostname="${hostname}" \
      2>&1 | tee -a /var/log/tailscale-setup.log
    if ! tailscale status >/dev/null 2>&1; then
      echo "ERROR: Tailscale enrollment failed — node will not be reachable via tailnet" >&2
    fi
%{ endif ~}

  # Security: remove secrets from disk after bootstrap completes.
  # Covers cloud-init logs, cached user-data (contains rke2_token), and journal.
  - |
    sleep 10
    truncate -s 0 /var/log/cloud-init-output.log 2>/dev/null || true
    truncate -s 0 /var/log/cloud-init.log 2>/dev/null || true
    rm -f /var/lib/cloud/instance/user-data.txt 2>/dev/null || true
    rm -f /var/lib/cloud/instance/scripts/runcmd 2>/dev/null || true
    journalctl --vacuum-time=1s -u cloud-init 2>/dev/null || true
