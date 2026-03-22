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
      cluster-cidr: "${pod_cidr}"
      service-cidr: "${service_cidr}"
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

%{ if cluster_init ~}
  # etcd discovery proxy — written only on cp-0 (cluster_init=true).
  #
  # rancher/hardened-etcd ≥ v3.5.16-k3s1 serves peer port 2380 as gRPC (HTTP/2)
  # only. When cp-1 and cp-2 start with no WAL they call getClusterFromRemotePeers()
  # which uses HTTP/1.1 GET to /members, /version, and /downgrade/enabled. Sending
  # HTTP/1.1 to a gRPC-only port yields EOF → etcd panic → crash-loop.
  #
  # This proxy (port 2383) speaks HTTPS/1.1 using the peer TLS certs and answers
  # the three discovery paths from the live etcd on localhost. An iptables PREROUTING
  # rule redirects 2380 → 2383 for the duration of the discovery window (120 s),
  # then the rule is removed so Raft gRPC traffic resumes on the real port 2380.
  - path: /usr/local/bin/etcd-discovery-proxy.py
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env python3
      """
      Temporary HTTPS/1.1 proxy for etcd peer-port discovery.
      Handles /members, /version, /downgrade/enabled from joining etcd peers.
      Runs on port 2383 with peer TLS; iptables redirects 2380 → 2383.
      Exits after 120 seconds so Raft gRPC can resume on real port 2380.
      """
      import ssl, json, subprocess, http.server, threading, time, sys

      PEER_CERT = '/var/lib/rancher/rke2/server/tls/etcd/peer-server-client.crt'
      PEER_KEY  = '/var/lib/rancher/rke2/server/tls/etcd/peer-server-client.key'
      PEER_CA   = '/var/lib/rancher/rke2/server/tls/etcd/peer-ca.crt'
      ETCDCTL   = '/var/lib/rancher/rke2/bin/etcdctl'
      EA = [
          '--endpoints',  'https://127.0.0.1:2379',
          '--cacert',     '/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt',
          '--cert',       '/var/lib/rancher/rke2/server/tls/etcd/server-client.crt',
          '--key',        '/var/lib/rancher/rke2/server/tls/etcd/server-client.key',
      ]

      def run(*args):
          r = subprocess.run([ETCDCTL] + EA + list(args),
                             capture_output=True, text=True, timeout=5)
          return json.loads(r.stdout)

      def cluster_id():
          return format(
              run('endpoint', 'status', '-w', 'json')[0]['Status']['header']['cluster_id'],
              '016x'
          )

      def members():
          out = []
          for m in run('member', 'list', '-w', 'json')['members']:
              e = {
                  'id': m['ID'],
                  'name': m.get('name', ''),
                  'peerURLs': m.get('peerURLs', []),
                  'clientURLs': m.get('clientURLs', []),
              }
              if m.get('isLearner'):
                  e['isLearner'] = True
              out.append(e)
          return out

      class Handler(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              try:
                  if self.path == '/members':
                      cid = cluster_id()
                      body = json.dumps(members()).encode()
                      self._ok(body, 'application/json', cid)
                  elif self.path == '/version':
                      self._ok(b'{"etcdserver":"3.5.26","etcdcluster":"3.5.0"}',
                               'application/json')
                  elif self.path == '/downgrade/enabled':
                      self._ok(b'"false"', 'application/json')
                  else:
                      self.send_response(404); self.end_headers()
              except Exception as ex:
                  sys.stderr.write(f'proxy error: {ex}\n')
                  self.send_response(500); self.end_headers()

          def _ok(self, body, ct, cluster_id_hex=None):
              self.send_response(200)
              self.send_header('Content-Type', ct)
              if cluster_id_hex:
                  self.send_header('X-Etcd-Cluster-ID', cluster_id_hex)
              self.send_header('Content-Length', str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def log_message(self, *args):
              pass  # suppress request logging

      srv = http.server.HTTPServer(('0.0.0.0', 2383), Handler)
      ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
      ctx.load_cert_chain(PEER_CERT, PEER_KEY)
      ctx.load_verify_locations(PEER_CA)
      ctx.verify_mode = ssl.CERT_REQUIRED
      srv.socket = ctx.wrap_socket(srv.socket, server_side=True)

      # Auto-exit after 120 s so iptables rule can be removed and Raft resumes
      def _shutdown():
          time.sleep(120)
          srv.shutdown()
      threading.Thread(target=_shutdown, daemon=True).start()

      sys.stdout.write('etcd-discovery-proxy listening on :2383\n')
      sys.stdout.flush()
      srv.serve_forever()
%{ endif ~}

runcmd:
%{ if enable_tailscale && cluster_init ~}
  # Install Tailscale BEFORE RKE2 so its IP is available for tls-san.
  # cp-0 advertises cluster_subnet_cidr as a subnet route so tailnet peers
  # can reach the cluster's private network without public API exposure.
  # Non-ephemeral so the device persists in the Tailscale admin console.
  - |
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up \
      --auth-key="${tailscale_auth_key}" \
      --hostname="${hostname}" \
      --advertise-routes="${cluster_subnet_cidr}" \
      --accept-routes \
      2>&1 | tee -a /var/log/tailscale-setup.log || true
    # Append Tailscale IP to tls-san so the API cert is valid over the VPN
    TS_IP=$(tailscale ip -4 2>/dev/null || true)
    if [ -n "$TS_IP" ]; then
      echo "        - \"$TS_IP\"" >> /etc/rancher/rke2/config.yaml
    fi
%{ endif ~}

  # For follower CP nodes (cluster_init=false): detect and append private IP.
  # For the first CP, node-ip is already written above as a static value.
%{ if !cluster_init ~}
  - |
    # Detect the Hetzner private network interface IP (eth1 or ens10)
    PRIVATE_IP=$(ip -4 addr show eth1 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || \
                 ip -4 addr show ens10 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || \
                 echo "")
    if [ -n "$PRIVATE_IP" ]; then
      # Append as a proper tls-san entry on a new line (not a sequence under node-ip)
      echo "        - \"$PRIVATE_IP\"" >> /etc/rancher/rke2/config.yaml
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

%{ if cluster_init ~}
  # Start etcd discovery proxy to allow cp-1 and cp-2 to join.
  # The proxy intercepts HTTP/1.1 peer-discovery requests that the gRPC-only
  # etcd port 2380 would otherwise reject with EOF.
  - |
    # Wait for etcd TLS certs (written by rke2-server on first start)
    timeout 120 bash -c '
      until [ -f /var/lib/rancher/rke2/server/tls/etcd/peer-server-client.crt ]; do
        echo "Waiting for etcd TLS certs..."
        sleep 5
      done
    '
    # Redirect port 2380 → 2383 for the discovery window
    iptables -t nat -I PREROUTING -p tcp --dport 2380 -j REDIRECT --to-port 2383
    # Start proxy in background; it exits after 120 s automatically
    nohup python3 /usr/local/bin/etcd-discovery-proxy.py \
      >> /var/log/etcd-discovery-proxy.log 2>&1 &
    # After 125 s, remove the iptables rule so Raft gRPC resumes on real 2380
    (sleep 125 && iptables -t nat -D PREROUTING -p tcp --dport 2380 -j REDIRECT --to-port 2383) &
%{ endif ~}

  # Add RKE2 binaries to PATH for interactive sessions
  - |
    echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >> /root/.bashrc
    echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> /root/.bashrc
    ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl 2>/dev/null || true

%{ if enable_tailscale && !cluster_init ~}
  # Install Tailscale on follower CP nodes AFTER RKE2 starts.
  # Joiners do not need to advertise routes — only cp-0 does.
  - |
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up \
      --auth-key="${tailscale_auth_key}" \
      --hostname="${hostname}" \
      --accept-routes \
      2>&1 | tee -a /var/log/tailscale-setup.log || true
%{ endif ~}

  # Security: truncate cloud-init logs to remove secrets from disk
  # The rke2_token appears in rendered cloud-init output logs
  - sleep 10
  - truncate -s 0 /var/log/cloud-init-output.log 2>/dev/null || true
  - truncate -s 0 /var/log/cloud-init.log 2>/dev/null || true
