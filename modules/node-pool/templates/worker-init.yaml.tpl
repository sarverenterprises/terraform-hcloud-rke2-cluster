#cloud-config
# RKE2 Worker Agent bootstrap
# Joins the cluster via the control plane load balancer (port 9345).

write_files:
  - path: /etc/rancher/rke2/config.yaml
    owner: root:root
    permissions: '0600'
    content: |
      server: https://${control_plane_lb_ip}:9345
      token: "${rke2_token}"
      cloud-provider-name: external
      cni: none
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

  # Detect and set the Hetzner private network IP for node-ip.
  # Uses subnet prefix matching (more reliable than interface names) with a
  # 60s retry loop to handle DHCP assignment lag on first boot.
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
      echo "node-ip: \"$PRIVATE_IP\"" >> /etc/rancher/rke2/config.yaml
      echo "Detected private IP: $PRIVATE_IP — written to config.yaml"
    else
      echo "FATAL: no private network IP detected after 60s — aborting to prevent wrong-IP join" >&2
      exit 1
    fi

  # Install RKE2 agent (retry up to 5 times for transient network failures)
  - |
    set -e
    for attempt in 1 2 3 4 5; do
      if curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="${rke2_version}" INSTALL_RKE2_TYPE="agent" sh -; then
        break
      fi
      if [ "$attempt" -eq 5 ]; then
        echo "FATAL: RKE2 agent install failed after 5 attempts" >&2
        exit 1
      fi
      echo "RKE2 install attempt $attempt failed — retrying in $((attempt * 15))s..." >&2
      sleep $((attempt * 15))
    done

  # Enable and start RKE2 agent service
  - systemctl enable rke2-agent.service
  - systemctl start rke2-agent.service

  # Add RKE2 binaries to PATH for interactive sessions
  - |
    echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >> /root/.bashrc

%{ if longhorn_volume_size > 0 ~}
  # Format and mount dedicated Hetzner block volume for Longhorn data.
  # Hetzner SCSI volumes appear at /dev/disk/by-id/scsi-0HC_Volume_<volume-id>
  # automount=true on hcloud_volume_attachment ensures the volume is attached before cloud-init runs.
  - |
    # Wait for the Hetzner volume device to appear (up to 60s)
    timeout 60 bash -c '
      until ls /dev/disk/by-id/scsi-0HC_Volume_* 2>/dev/null | head -1 | grep -q .; do
        echo "Waiting for Hetzner volume to appear..."
        sleep 3
      done
    '
    DISK=$(ls /dev/disk/by-id/scsi-0HC_Volume_* | head -1)
    echo "Found Longhorn data volume: $DISK"
    # Format only if not already formatted (ensures idempotency on node restart)
    if ! blkid "$DISK" 2>/dev/null | grep -q ext4; then
      mkfs.ext4 -F "$DISK"
      echo "Formatted $DISK as ext4"
    fi
    mkdir -p /mnt/longhorn
    # Add to fstab for persistence across reboots (nofail prevents boot failure if disk missing)
    if ! grep -q "$(basename $DISK)" /etc/fstab 2>/dev/null; then
      echo "$DISK /mnt/longhorn ext4 defaults,nofail,discard 0 2" >> /etc/fstab
    fi
    mount /mnt/longhorn || mountpoint -q /mnt/longhorn
    echo "Longhorn data volume mounted at /mnt/longhorn"
%{ endif ~}

%{ if enable_tailscale ~}
  # Install and configure Tailscale for VPN mesh SSH access
  - |
    for attempt in 1 2 3; do
      curl -fsSL https://tailscale.com/install.sh | sh && break
      echo "Tailscale install attempt $attempt failed — retrying in $((attempt * 10))s..." >&2
      sleep $((attempt * 10))
    done
    tailscale up \
      --auth-key="${tailscale_auth_key}" \
      --hostname="${hostname}" \
      --ephemeral \
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
