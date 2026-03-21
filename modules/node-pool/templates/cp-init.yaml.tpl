#cloud-config
# RKE2 Control Plane bootstrap
# cluster_init=${cluster_init} — true for first node (initializes cluster), false for joiners

write_files:
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
  # For follower CP nodes (cluster_init=false): detect and append private IP.
  # For the first CP, node-ip is already written above as a static value.
%{ if !cluster_init ~}
  - |
    # Detect the Hetzner private network interface IP (eth1 or ens10)
    PRIVATE_IP=$(ip -4 addr show eth1 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || \
                 ip -4 addr show ens10 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || \
                 echo "")
    if [ -n "$PRIVATE_IP" ]; then
      echo "node-ip: $PRIVATE_IP" >> /etc/rancher/rke2/config.yaml
      # Also add to TLS SANs
      echo "  - \"$PRIVATE_IP\"" >> /etc/rancher/rke2/config.yaml
    fi
%{ endif ~}

  # Install RKE2 server
  - |
    set -e
    curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="${rke2_version}" INSTALL_RKE2_TYPE="server" sh -

  # Create required directories
  - mkdir -p /var/lib/rancher/rke2/server/manifests/

  # Enable and start RKE2 server service
  - systemctl enable rke2-server.service
  - systemctl start rke2-server.service

  # Wait for RKE2 server to be running and kubeconfig to be available
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

  # Add RKE2 binaries to PATH for interactive sessions
  - |
    echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >> /root/.bashrc
    echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> /root/.bashrc
    ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl 2>/dev/null || true

%{ if enable_tailscale ~}
  # Install and configure Tailscale for VPN mesh SSH access
  # Note: auth key is ephemeral (device removed from Tailnet on shutdown)
  - |
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up \
      --auth-key="${tailscale_auth_key}" \
      --hostname="${hostname}" \
      --ephemeral \
      --accept-routes \
      2>&1 | tee -a /var/log/tailscale-setup.log || true
%{ endif ~}

  # Security: truncate cloud-init logs to remove secrets from disk
  # The rke2_token appears in rendered cloud-init output logs
  - sleep 10
  - truncate -s 0 /var/log/cloud-init-output.log 2>/dev/null || true
  - truncate -s 0 /var/log/cloud-init.log 2>/dev/null || true
