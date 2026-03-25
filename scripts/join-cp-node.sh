#!/usr/bin/env bash
# join-cp-node.sh — Run on a CP joiner node to wipe partial state and start rke2-server.
#
# Usage: bash -s -- <LABEL> < join-cp-node.sh
#   LABEL  Log prefix string (e.g. "CP-1" or "CP-2") — for output identification only.
#
# Called by the terraform_data.join_cps provisioner in main.tf. The provisioner
# SSHes to each CP joiner sequentially and pipes this script via stdin.
#
# Safety: if rke2-server is already active (e.g. provisioner re-run after a
# successful join), the wipe is skipped and the script exits 0 immediately.
# This makes the script idempotent against Terraform state rm + re-apply.

set -euo pipefail

LABEL="${1:-node}"

# ---------------------------------------------------------------------------
# 1. Wait for RKE2 binary (cloud-init may still be installing), up to 300s.
# ---------------------------------------------------------------------------
echo "[$LABEL] Waiting for /usr/local/bin/rke2 ..." >&2
for i in $(seq 1 60); do
  [ -x /usr/local/bin/rke2 ] && break
  if [ "$i" -eq 60 ]; then
    echo "[$LABEL] ERROR: /usr/local/bin/rke2 not found after 300s." >&2
    exit 1
  fi
  sleep 5
done
echo "[$LABEL] RKE2 binary found." >&2

# ---------------------------------------------------------------------------
# 2. Liveness guard: skip wipe if rke2-server is already active.
#    Makes the provisioner idempotent on retry — safe on a live cluster member.
# ---------------------------------------------------------------------------
if systemctl is-active rke2-server --quiet 2>/dev/null; then
  echo "[$LABEL] rke2-server is already active — skipping wipe and start." >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Wipe partial TLS/DB state left by any prior failed join attempt.
#    These directories cause RKE2 to bypass server: config and run as a
#    standalone primary instead of joining the existing cluster.
# ---------------------------------------------------------------------------
echo "[$LABEL] Wiping partial server state (tls/, db/) ..." >&2
rm -rf /var/lib/rancher/rke2/server/tls /var/lib/rancher/rke2/server/db

# ---------------------------------------------------------------------------
# 4. Start the join.
# ---------------------------------------------------------------------------
echo "[$LABEL] Starting rke2-server ..." >&2
systemctl start rke2-server

# ---------------------------------------------------------------------------
# 5. Poll for active status (300s ceiling, ~5s intervals = 60 attempts).
#    Short-circuit on crash-loop to avoid waiting the full 300s.
# ---------------------------------------------------------------------------
echo "[$LABEL] Waiting for rke2-server to become active ..." >&2
for i in $(seq 1 60); do
  if systemctl is-active rke2-server --quiet 2>/dev/null; then
    echo "[$LABEL] rke2-server is active (attempt $i)." >&2
    exit 0
  fi
  if systemctl is-failed rke2-server --quiet 2>/dev/null; then
    echo "[$LABEL] ERROR: rke2-server entered failed state." >&2
    systemctl status rke2-server --no-pager -l >&2 || true
    exit 1
  fi
  sleep 5
done

echo "[$LABEL] ERROR: rke2-server did not become active within 300s." >&2
exit 1
