---
date: 2026-03-23
topic: cp-bootstrap-reliability
---

# Control Plane Bootstrap Reliability

## Problem Frame

Two bootstrap failure modes require manual intervention today, discovered during v0.4.17/v0.4.18 e2e testing:

1. **etcd member dir corruption**: The `rke2-etcd-recovery.sh` ExecStartPre script kills orphaned etcd on startup, but leaves the member directory intact. When the member dir holds stale multi-node WAL/snap state (e.g., from a 3-node cluster where CP-0 crashed hard), rke2-server's TLS handshake to etcd still fails even after the orphan is killed — because etcd reinitializes with the stale cluster config.

2. **CP split-brain → CoreDNS scheduler deadlock**: A joiner CP that fails to fully join the cluster can still register the `node-role.kubernetes.io/control-plane=true` label. The RKE2 HelmChart controller's `helm-install-rke2-coredns` Job targets CP nodes via `node-selector`, so it keeps scheduling the installer pod on the broken CP. The `wait_for_coredns` script force-deletes stuck pods, but: (a) pods keep respawning to the same broken node, and (b) after enough force-deletes the Job enters exponential backoff (up to 80s+), leaving no active pod. The 600s timeout expires, blocking CCM and CSI.

## Requirements

- R1. `rke2-etcd-recovery.sh` clears the etcd member directory (`/var/lib/rancher/rke2/server/db/etcd/member`) in addition to killing the orphaned process. This runs only when an orphan is detected (crash scenario); normal graceful restarts leave etcd not running, so the script remains a no-op.

- R2. `wait_for_coredns` detects CP nodes with `NotReady`/`Unknown` status that have stuck installer pods assigned to them, and cordons those nodes so the scheduler stops targeting them. The stuck pod is then force-deleted; the replacement pod spawns on a healthy CP node.

- R3. `wait_for_coredns` resets Job backoff by deleting the `helm-install-rke2-coredns` Job after repeated force-delete cycles without progress. The HelmChart controller recreates the Job with a clean failure counter. Trigger: after force-deleting pods more than N times (suggested: 3 attempts, ~150s into the wait).

## Success Criteria

- A fresh 3-CP deploy reaches all V1–V7 checks without manual intervention, even when one joiner CP fails to properly join.
- Restarting rke2-server on CP-0 after a crash succeeds on the first attempt without manual member dir cleanup.
- `terraform destroy` remains clean (no state rm workarounds, 34 resources destroyed).

## Scope Boundaries

- No cloud-init prevention logic for split-brain (not in scope — recovery-only approach chosen).
- Node objects are cordoned, not deleted — leaves the door open for a CP to self-heal.
- Only `helm-install-rke2-coredns` Job is reset; no other Jobs are touched.
- etcd member dir is backed up before removal (optional, but good hygiene if trivially cheap).

## Key Decisions

- **Always clear member dir when orphan killed**: Safe because the script is a no-op on clean restarts. Prevents TLS failures unconditionally rather than needing a second recovery pass.
- **Cordon over delete**: Leaves node recoverable; cordon is reversible with `kubectl uncordon`. If a node heals and rejoins, manual uncordon restores it.
- **Job deletion threshold at 3 force-delete cycles**: Balances giving the Job a fair chance vs. waiting too long to reset backoff.

## Dependencies / Assumptions

- R1 applies to CP nodes only (workers don't run etcd).
- R2/R3 run inside the `wait_for_coredns` `local-exec` provisioner, which has KUBECONFIG access on the operator's machine.
- Job reset (R3) relies on RKE2's HelmChart controller automatically recreating the Job — confirmed behavior in v0.4.18 testing.

## Outstanding Questions

### Deferred to Planning

- [Affects R1][Technical] Should member dir backup (`cp -r member member.bak.$(date +%s)`) be included, or is `rm -rf` sufficient given the orphan-detected safety gate?
- [Affects R3][Technical] Should Job deletion in R3 also trigger a fresh cordon check (R2), or are they independent loops?

## Next Steps

→ `/ce:plan` for structured implementation planning
