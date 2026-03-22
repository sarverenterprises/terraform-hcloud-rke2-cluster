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
  # only. When cp-1 and cp-2 start they call getClusterFromRemotePeers() which
  # uses HTTP/1.1 GET to /members, /version, and /downgrade/enabled. Sending
  # HTTP/1.1 to a gRPC-only port yields EOF → etcd panic → crash-loop.
  #
  # This proxy (port 2383) speaks HTTPS using the peer TLS certs:
  #   - HTTP/1.1 requests  → served directly (discovery endpoints)
  #   - HTTP/2 / gRPC      → forwarded to real etcd on localhost:2380
  #
  # iptables PREROUTING redirects incoming port 2380 → 2383 for the full
  # 600-second window. Both discovery AND Raft gRPC transit the proxy cleanly.
  # After 605 s the rule is removed and Raft reconnects directly to port 2380.
  - path: /usr/local/bin/etcd-discovery-proxy.py
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env python3
      """
      HTTPS proxy for etcd peer-port discovery and gRPC forwarding.

      Listens on 0.0.0.0:2383 with peer TLS certs.
        HTTP/1.1  -> serves /members, /version, /downgrade/enabled, /raft/probing
        HTTP/2    -> transparently forwards to real etcd at 127.0.0.1:2380

      iptables keeps 2380 → 2383 for 605 s so both discovery and Raft go here.
      Proxy exits after 600 s; after that Raft reconnects directly to real 2380.
      """
      import ssl, json, subprocess, socket, threading, time, sys, glob

      PEER_CERT = '/var/lib/rancher/rke2/server/tls/etcd/peer-server-client.crt'
      PEER_KEY  = '/var/lib/rancher/rke2/server/tls/etcd/peer-server-client.key'
      PEER_CA   = '/var/lib/rancher/rke2/server/tls/etcd/peer-ca.crt'
      EA = [
          '--endpoints',  'https://127.0.0.1:2379',
          '--cacert',     '/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt',
          '--cert',       '/var/lib/rancher/rke2/server/tls/etcd/server-client.crt',
          '--key',        '/var/lib/rancher/rke2/server/tls/etcd/server-client.key',
      ]

      def find_etcdctl():
          # etcdctl lives inside the hardened-etcd containerd snapshot
          paths = glob.glob(
              '/var/lib/rancher/rke2/agent/containerd/io.containerd.snapshotter'
              '.v1.overlayfs/snapshots/*/fs/usr/local/bin/etcdctl'
          )
          return paths[0] if paths else '/var/lib/rancher/rke2/bin/etcdctl'

      def run(*args):
          r = subprocess.run([find_etcdctl()] + EA + list(args),
                             capture_output=True, text=True, timeout=10)
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

      # Outbound TLS context for forwarding gRPC to real etcd
      ctx_out = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
      ctx_out.load_cert_chain(PEER_CERT, PEER_KEY)
      ctx_out.load_verify_locations(PEER_CA)
      ctx_out.check_hostname = False
      ctx_out.verify_mode = ssl.CERT_REQUIRED

      def pipe(src, dst):
          try:
              while True:
                  data = src.recv(32768)
                  if not data:
                      break
                  dst.sendall(data)
          except Exception:
              pass

      def forward_grpc(tls_in, addr):
          """Forward HTTP/2 gRPC connection to real etcd on localhost:2380."""
          try:
              backend_raw = socket.create_connection(('127.0.0.1', 2380), timeout=10)
              backend = ctx_out.wrap_socket(backend_raw)
              t = threading.Thread(target=pipe, args=(backend, tls_in), daemon=True)
              t.start()
              pipe(tls_in, backend)
          except Exception as e:
              sys.stderr.write(f'gRPC forward {addr}: {e}\n')
          finally:
              try: tls_in.close()
              except: pass

      def serve_http11(tls_in, addr):
          """Serve HTTP/1.1 etcd peer-discovery endpoints."""
          try:
              buf = b''
              while b'\r\n\r\n' not in buf:
                  chunk = tls_in.recv(4096)
                  if not chunk:
                      return
                  buf += chunk

              first_line = buf.split(b'\r\n')[0].decode(errors='replace')
              parts = first_line.split(' ')
              if len(parts) < 2:
                  return
              path = parts[1]

              if path == '/members':
                  cid = cluster_id()
                  body = json.dumps(members()).encode()
                  resp = (
                      f'HTTP/1.1 200 OK\r\n'
                      f'Content-Type: application/json\r\n'
                      f'X-Etcd-Cluster-ID: {cid}\r\n'
                      f'Content-Length: {len(body)}\r\n\r\n'
                  ).encode() + body
                  sys.stdout.write(f'proxy: {addr[0]} GET /members 200\n')
              elif path == '/version':
                  body = b'{"etcdserver":"3.5.26","etcdcluster":"3.5.0"}'
                  resp = f'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n'.encode() + body
              elif path in ('/downgrade/enabled', '/raft/probing'):
                  body = b'"false"'
                  resp = f'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n'.encode() + body
              else:
                  resp = b'HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n'
                  sys.stdout.write(f'proxy: {addr[0]} GET {path} 404\n')
              tls_in.sendall(resp)
          except Exception as e:
              sys.stderr.write(f'HTTP/1.1 error {addr}: {e}\n')
          finally:
              try: tls_in.close()
              except: pass

      # Server TLS context — advertises both h2 and http/1.1 via ALPN
      ctx_srv = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
      ctx_srv.load_cert_chain(PEER_CERT, PEER_KEY)
      ctx_srv.load_verify_locations(PEER_CA)
      ctx_srv.verify_mode = ssl.CERT_REQUIRED
      ctx_srv.set_alpn_protocols(['h2', 'http/1.1'])

      def handle(raw_conn, addr):
          try:
              tls = ctx_srv.wrap_socket(raw_conn, server_side=True)
              alpn = tls.selected_alpn_protocol()
              if alpn == 'h2':
                  forward_grpc(tls, addr)
              else:
                  serve_http11(tls, addr)
          except Exception as e:
              sys.stderr.write(f'TLS handshake {addr}: {e}\n')
              try: raw_conn.close()
              except: pass

      stop = threading.Event()

      def acceptor():
          srv_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
          srv_sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
          srv_sock.bind(('0.0.0.0', 2383))
          srv_sock.listen(32)
          srv_sock.settimeout(1.0)
          while not stop.is_set():
              try:
                  conn, addr = srv_sock.accept()
                  threading.Thread(target=handle, args=(conn, addr), daemon=True).start()
              except socket.timeout:
                  continue
              except Exception:
                  break
          srv_sock.close()

      threading.Thread(target=lambda: (time.sleep(600), stop.set()), daemon=True).start()

      sys.stdout.write('etcd-discovery-proxy v3 listening on :2383 (HTTP/1.1 + gRPC forward)\n')
      sys.stdout.flush()
      acceptor()
      sys.stdout.write('etcd-discovery-proxy exiting\n')
      sys.stdout.flush()
%{ endif ~}

runcmd:
%{ if enable_tailscale && cluster_init ~}
  # Install Tailscale BEFORE RKE2 so its IP is available for tls-san.
  # cp-0 advertises cluster_subnet_cidr as a subnet route so tailnet peers
  # can reach the cluster's private network without public API exposure.
  - |
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up \
      --auth-key="${tailscale_auth_key}" \
      --hostname="${hostname}" \
      --advertise-routes="${cluster_subnet_cidr}" \
      --accept-routes \
      2>&1 | tee -a /var/log/tailscale-setup.log || true
    TS_IP=$(tailscale ip -4 2>/dev/null || true)
    if [ -n "$TS_IP" ]; then
      sed -i '/^tls-san:$/a\  - "'"$TS_IP"'"' /etc/rancher/rke2/config.yaml
    fi
%{ endif ~}

%{ if !cluster_init ~}
  # Follower CP: detect private network IP and write node-ip + tls-san entry
  # BEFORE RKE2 starts so etcd uses the private IP from the very first boot.
  # Hetzner private network interface is typically eth1, ens10, or enp7s0.
  - |
    PRIVATE_IP=$(ip -4 addr show eth1  2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || \
                 ip -4 addr show ens10 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || \
                 ip -4 addr show enp7s0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || \
                 echo "")
    if [ -n "$PRIVATE_IP" ]; then
      printf '\nnode-ip: "%s"\n' "$PRIVATE_IP" >> /etc/rancher/rke2/config.yaml
      sed -i '/^tls-san:$/a\  - "'"$PRIVATE_IP"'"' /etc/rancher/rke2/config.yaml
      echo "Detected private IP: $PRIVATE_IP — written to config.yaml"
    else
      echo "WARNING: no private network IP detected; etcd will use public IP"
    fi

  # Wait for cp-0's supervisor (port 9345) before proceeding.
  # This prevents the follower from racing ahead of cp-0's etcd initialization,
  # which would cause repeated failed join attempts and corrupt WAL state.
  - |
    echo "Waiting for cp-0 supervisor at ${first_cp_ip}:9345 ..."
    timeout 600 bash -c \
      'until nc -z -w3 ${first_cp_ip} 9345 2>/dev/null; do sleep 10; done'
    echo "cp-0 supervisor is ready — proceeding with RKE2 install"
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
  # Start etcd discovery proxy to allow cp-1 and cp-2 to join cleanly.
  #
  # rancher/hardened-etcd serves port 2380 as gRPC-only. Joining nodes call
  # getClusterFromRemotePeers() (HTTP/1.1 GET /members) which would fail against
  # a gRPC-only port. The proxy handles HTTP/1.1 discovery AND forwards gRPC
  # Raft connections to real etcd — iptables redirect stays up for the full
  # 600 s window so no timing race between discovery and Raft phases.
  - |
    # Wait for etcd TLS certs to be written by rke2-server
    timeout 120 bash -c '
      until [ -f /var/lib/rancher/rke2/server/tls/etcd/peer-server-client.crt ]; do
        echo "Waiting for etcd TLS certs..."
        sleep 5
      done
    '
    # Redirect all incoming port 2380 traffic through the proxy
    iptables -t nat -I PREROUTING -p tcp --dport 2380 -j REDIRECT --to-port 2383
    # Start proxy (handles HTTP/1.1 discovery + gRPC forwarding)
    nohup python3 /usr/local/bin/etcd-discovery-proxy.py \
      >> /var/log/etcd-discovery-proxy.log 2>&1 &
    # Remove iptables rule 605 s after proxy exits so Raft reconnects directly
    (sleep 605 && iptables -t nat -D PREROUTING -p tcp --dport 2380 \
      -j REDIRECT --to-port 2383 2>/dev/null || true) &
%{ endif ~}

  # Add RKE2 binaries to PATH for interactive sessions
  - |
    echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' >> /root/.bashrc
    echo 'export KUBECONFIG=/etc/rancher/rke2/rke2.yaml' >> /root/.bashrc
    ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl 2>/dev/null || true

%{ if enable_tailscale && !cluster_init ~}
  # Install Tailscale on follower CP nodes AFTER RKE2 starts.
  # Joiners do not advertise routes — only cp-0 does.
  - |
    curl -fsSL https://tailscale.com/install.sh | sh
    tailscale up \
      --auth-key="${tailscale_auth_key}" \
      --hostname="${hostname}" \
      --accept-routes \
      2>&1 | tee -a /var/log/tailscale-setup.log || true
%{ endif ~}

  # Security: truncate cloud-init logs to remove secrets from disk
  - sleep 10
  - truncate -s 0 /var/log/cloud-init-output.log 2>/dev/null || true
  - truncate -s 0 /var/log/cloud-init.log 2>/dev/null || true
