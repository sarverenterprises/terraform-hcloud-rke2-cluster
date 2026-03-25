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
      echo "WARNING: no private network IP detected; node-ip not set"
    fi

  # Install RKE2 agent
  - |
    set -e
    curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="${rke2_version}" INSTALL_RKE2_TYPE="agent" sh -

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
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up \
      --auth-key="${tailscale_auth_key}" \
      --hostname="${hostname}" \
      --ephemeral \
      2>&1 | tee -a /var/log/tailscale-setup.log || true
%{ endif ~}

  # Security: truncate cloud-init logs to remove secrets (rke2_token) from disk
  - sleep 10
  - truncate -s 0 /var/log/cloud-init-output.log 2>/dev/null || true
  - truncate -s 0 /var/log/cloud-init.log 2>/dev/null || true
