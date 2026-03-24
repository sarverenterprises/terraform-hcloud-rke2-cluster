---
title: "fix: Automate CP Bootstrap Failure Recovery"
type: fix
status: active
date: 2026-03-23
deepened: 2026-03-23
origin: docs/brainstorms/2026-03-23-cp-bootstrap-reliability-requirements.md
---

# fix: Automate CP Bootstrap Failure Recovery

## Enhancement Summary

**Deepened on:** 2026-03-23
**Agents used:** security-sentinel, code-simplicity-reviewer, architecture-strategist,
best-practices-researcher, framework-docs-researcher, performance-oracle

### Key Improvements Discovered

1. **Critical path bug fixed**: The plan used a relative path `member` in `cp -r` and `rm -rf`
   inside `rke2-etcd-recovery.sh`. In a systemd ExecStartPre unit, the CWD is `/`. The absolute
   `MEMBER_DIR` variable must be used throughout — the `[ -d ]` check already used the absolute
   path but the cp/rm operations did not.

2. **Simplified cordon logic**: Replaced per-pod node lookup (2 kubectl calls per pod + cordon)
   with a single `kubectl get nodes -l control-plane=true` label-selector query that captures all
   NotReady CP nodes in one call. Eliminates the unquoted-variable security risk, handles
   unscheduled (Pending, no node assignment) pods correctly, and reduces worst-case API calls from
   9 to 2 for the cordon path.

3. **Simplified Job reset trigger**: Replaced `FORCE_DELETE_COUNT` counter (4 moving parts:
   init, increment, compare, reset) with a fixed elapsed-time guard at `ELAPSED -eq 300` (one
   conditional). Same effect — resets Job backoff at the ~5-minute mark — with less state.

4. **`--request-timeout=15s` on all kubectl calls**: Unbounded kubectl calls against an
   unstable bootstrap API server can hang indefinitely. Added `--request-timeout=15s` to all new
   (and the existing `kubectl get pods`) calls for safety.

5. **Cordon visibility**: Cordon is a silent cluster state mutation. Added explicit `echo` to
   stdout so it appears in `terraform apply` output. Operators must know a node was cordoned.

6. **Bootstrap scope risk documented**: Clearing the etcd member dir on CP-0 is not scoped to
   bootstrap-only scenarios. On a stable 3-CP cluster where CP-0 crashes with orphaned etcd,
   clearing the member dir creates a new single-node cluster, leaving CP-1/CP-2 unable to rejoin.

### New Considerations

- `rke2 server --cluster-reset` is RKE2's canonical etcd recovery mechanism (preserves WAL;
  moves old data to `etcd-old-<ts>/`). Documented as the safer alternative for future work.
- `kubectl cordon` is idempotent (already-cordoned node returns exit 0). No pre-check needed
  for the "already cordoned" case — only need to guard against `node not found` (exit 1).
- Deleting and recreating a Kubernetes Job resets the backoff counter unconditionally (new UID,
  fresh `.status`). HelmChart controller recreates the deleted Job within seconds (event-driven,
  no periodic resync).
- etcd `member/snap/db` is BoltDB; `member/wal/*.wal` are Raft write-ahead logs. Clearing the
  member dir on a single-node etcd is equivalent to a factory reset — no data recovery.

---

## Overview

Two bootstrap failure modes discovered in v0.4.17/v0.4.18 e2e testing currently require manual
intervention. This plan automates both:

1. The etcd orphan-recovery script kills stale processes but leaves the member directory intact,
   causing persistent TLS handshake failures when the member dir holds stale multi-node WAL state.
2. The `wait_for_coredns` provisioner force-deletes stuck CoreDNS installer pods but does not
   cordon the broken CP node responsible for the failures, nor does it reset the Job's exponential
   backoff counter after repeated force-deletes.

The changes touch two independent files and are designed for parallel implementation.

## Problem Frame

(see origin: docs/brainstorms/2026-03-23-cp-bootstrap-reliability-requirements.md)

On a fresh 3-CP deploy, if a joiner CP fails to properly join but still registers
`node-role.kubernetes.io/control-plane=true`, the CoreDNS HelmChart Job continuously schedules
to that broken node. The `wait_for_coredns` provisioner keeps force-deleting the stuck pod, but
the replacement respawns to the same node. After ~8 force-deletes the Job enters exponential
backoff (first failure: 0s delay; second: 10s; fourth: 40s; eighth: 80s+; cap: 10 min) and the
600s gate expires — blocking CCM and CSI.

Separately, when rke2-server crashes and etcd is left as an orphan, killing the orphan is
insufficient if the member dir holds stale 3-node WAL state. Etcd re-initializes from stale
config and rke2-server's TLS handshake still fails.

## Requirements Trace

- R1. `rke2-etcd-recovery.sh` clears the etcd member dir in addition to killing the orphan.
      Runs only inside the existing orphan-detected safety gate (crash scenario only).
- R2. `wait_for_coredns` cordons CP nodes with `NotReady`/`Unknown` status after stuck installer
      pods are detected, so the scheduler stops targeting those nodes.
- R3. `wait_for_coredns` deletes the `helm-install-rke2-coredns` Job at a fixed elapsed threshold
      to reset the backoff counter. HelmChart controller recreates it with 0 failures within
      seconds (event-driven, no resync period).

## Scope Boundaries

- No cloud-init prevention logic for split-brain CP nodes (recovery-only approach, see origin).
- Node objects are cordoned, not deleted — recoverable if the node self-heals.
- Only `helm-install-rke2-coredns` Job is deleted; no other Jobs are touched.
- R1 applies to CP nodes only (workers do not run etcd).

## Context & Research

### Relevant Code and Patterns

- `modules/node-pool/templates/cp-init.yaml.tpl` lines 18–32: current `rke2-etcd-recovery.sh`
  content block. Embedded under `write_files` with `permissions: '0755'`. Systemd reload in
  `runcmd` at line 133 before `systemctl start` picks up changes on first boot.
- `modules/addons/coredns_wait.tf`: full `null_resource.wait_for_coredns`. Shell variables:
  `KUBECONFIG_PATH`, `MAX_WAIT=600`, `POLL_INTERVAL=10`, `ELAPSED=0`, `STUCK`. Uses
  `kubectl --kubeconfig "$KUBECONFIG_PATH"` pattern throughout. Force-delete guard activates at
  `ELAPSED -ge 120`. Uses `interpreter = ["/bin/bash", "-c"]`.
- `modules/addons/ccm.tf` line 67: the CCM `depends_on` fix (v0.4.18). Must not be disturbed —
  CCM deliberately does not depend on `wait_for_coredns` to avoid the bootstrap deadlock.
- No existing `kubectl cordon` pattern in the codebase — Unit 2 introduces the first usage.
  Follow the same `--kubeconfig "$KUBECONFIG_PATH" 2>/dev/null || true` guard style.

### Institutional Learnings

- etcd-recovery.sh: pgrep pattern `etcd --config-file=/var/lib/rancher/rke2` is already
  specific enough to avoid matching SSH shell processes (v0.4.17 fix). Do not change it.
- Member dir path is stable: `/var/lib/rancher/rke2/server/db/etcd/member`.
- After clearing member dir + restarting rke2-server, etcd bootstraps as a fresh single-node
  cluster. On a 3-CP cluster, CP-1/CP-2 cannot rejoin. Workers can, and the cluster remains
  functional. This is the accepted trade-off (see origin doc).
- Job deletion resets backoff (R3): confirmed in v0.4.18 testing AND confirmed by framework
  docs — new Job UID = fresh counter. HelmChart controller recreates within seconds.
- `wait_for_coredns` early-exit guard (`if [ -z "$KUBECONFIG_PATH" ]`) must be preserved —
  makes the provisioner a no-op on subsequent applies when DNS is already running.

### External References

- Kubernetes Job backoff: first failure: no delay; sequence: 10s, 20s, 40s… capped at 10m.
  Delete+recreate resets counter (new UID). No `.status` patching mechanism exists.
- `kubectl cordon`: sets `spec.unschedulable: true`. Idempotent (already-cordoned → exit 0).
  Node not found → exit 1 (must guard). Kubernetes v1.25+.
- HelmChart controller (k3s-io/helm-controller): purely event-driven. Deleted Job → watch
  event → recreation in seconds. No periodic resync timer.
- etcd member dir: `member/wal/*.wal` (Raft WAL), `member/snap/db` (BoltDB). Empty dir →
  fresh single-node bootstrap. `rke2 server --cluster-reset` is the canonical alternative that
  preserves WAL.

## Key Technical Decisions

- **Use absolute `MEMBER_DIR` variable throughout etcd script**: `cp -r` and `rm -rf` in
  ExecStartPre have CWD `/` (systemd default). The original plan used `member` (relative).
  Must use `$MEMBER_DIR` (absolute) for both operations to avoid silent no-ops or wrong-path
  deletes.

- **Skip the backup in Unit 1**: The server that runs ExecStartPre will be destroyed as part of
  the module lifecycle. A backup of the etcd member dir has no recovery value — there are no
  healthy peers to restore to, and restoring from `member.bak.*` is not how etcd recovery works
  (official path: `rke2 server --cluster-reset --cluster-reset-restore-path=<snapshot>`).
  The script should log what it did with explicit echo lines instead of relying on backup as a
  safety net. (See simplicity review: YAGNI — one line of complexity, zero operational value.)

- **Single label-selector cordon query instead of per-pod lookup**: `kubectl get nodes
  -l node-role.kubernetes.io/control-plane=true` returns all CP nodes in one call. Filter for
  `NotReady` or `Unknown` status, then cordon each. This eliminates per-pod `spec.nodeName`
  lookups (which return empty for Pending/unscheduled pods, silently skipping the most common
  case), reduces API calls from N×3 to 2, and avoids the unquoted-variable injection risk of
  building kubectl arguments from jsonpath output.
  (see origin: R2 — "cordons CP nodes … before force-deleting those pods")

- **Fixed elapsed threshold for Job reset**: `if [ "$ELAPSED" -eq 300 ]` replaces
  `FORCE_DELETE_COUNT`. At the 300s mark (halfway through the 600s gate), delete the Job once.
  `--ignore-not-found=true` makes this idempotent. One conditional, no state. ELAPSED-based
  trigger is semantically clearer than counting force-delete cycles.
  (see origin: R3 — "after force-deleting pods more than N times"; resolved to time-based)

- **`--request-timeout=15s` on all new kubectl calls**: During bootstrap, the API server may
  be intermittently slow or unresponsive. All new kubectl calls must carry this flag to prevent
  the provisioner loop from hanging. The existing `kubectl wait --timeout=5s` shows the intent;
  all new calls should be consistent.

- **Cordon emits visible log line to stdout**: `echo "  Cordoning NotReady/Unknown CP node:
  $NODE"` before the cordon call. This ensures the cordon action appears in `terraform apply`
  output — making the silent cluster state mutation visible to operators.

- **Cordon triggers on `False` OR `Unknown` node status, not empty**: Empty means the node has
  never reported a Ready condition (still initializing). Cordoning an initializing node would
  create a false-positive bootstrap failure. Only `False` and `Unknown` indicate a node that has
  been in the cluster and is now unhealthy.

- **Version bump: v0.4.19**: Both fixes are patch-level — no interface, variable, or output
  changes.

## Open Questions

### Resolved During Planning

- *Should member dir be backed up or just rm -rf'd?* — Skip backup. YAGNI. Server is destroyed
  anyway; backup has no recovery value. Log the action instead. (Simplicity review)
- *Should R3 Job deletion trigger a fresh cordon check?* — Not needed; they are sequential in
  the same polling cycle at `ELAPSED -eq 300`.
- *Per-pod lookup or label-selector for cordon?* — Label-selector. Simpler, fewer calls, handles
  unscheduled pods correctly. (Simplicity + security review)
- *Counter or elapsed threshold for Job reset?* — Elapsed threshold at 300s. (Simplicity review)

### Deferred to Implementation

- The label-selector approach cordons ALL NotReady/Unknown CP nodes, not just the ones with
  stuck pods. Implementer should confirm this is acceptable for the target cluster sizes (1–3 CP
  nodes typical; cordoning an extra unhealthy CP that isn't involved in CoreDNS scheduling is
  still correct behavior).
- `rke2 server --cluster-reset` as a future alternative to `rm -rf member/`: documents that
  a safer WAL-preserving reset exists, but requires invoking the rke2 binary from within
  ExecStartPre (path complexity). Track as a v0.5.0 candidate.
- ELAPSED undercounting: if the per-CP cordon loop takes >10s (slow API server), `ELAPSED`
  undercounts actual wall time. The effect is that the 300s Job-deletion threshold fires slightly
  later than 300s of wall time. Implementer should add a comment noting this is a loop-cycle
  counter, not a wall-clock timer.
- jsonpath `[?(@.type=="Ready")]` filter: if using any per-node jsonpath calls in future, always
  single-quote the expression and test for `== "True"` — empty string is returned (not error)
  when the condition is absent.

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not
> implementation specification. The implementing agent should treat it as context, not code
> to reproduce.*

### Unit 1 — etcd-recovery.sh extension

```
MEMBER_DIR = "/var/lib/rancher/rke2/server/db/etcd/member"   [renamed, was inline]

ExecStartPre runs rke2-etcd-recovery.sh
  → pgrep for orphaned etcd
  → if found:
      kill -9 PID
      sleep 2
      log: "orphaned etcd killed"
      if $MEMBER_DIR exists:                                    [NEW]
          rm -rf $MEMBER_DIR                                    [NEW — absolute path, no backup]
          log: "member dir cleared — etcd will reinitialize"   [NEW — visible in journal]
          else: log: "member dir absent — nothing to clear"     [NEW — auditable no-op]
      log: "done — rke2-server will restart etcd cleanly"
  → rke2-server starts; etcd bootstraps fresh as single-node
```

Note: On a stable 3-CP cluster, this path demotes CP-0 to a new single-node etcd. CP-1/CP-2
cannot rejoin without manual `rke2 server --cluster-reset` on each. This is the accepted trade-off
for bootstrap-time-only use; the risk is documented in Risks & Dependencies below.

### Unit 2 — wait_for_coredns enhanced polling loop

```
loop until CoreDNS ready or MAX_WAIT exceeded:
  if CoreDNS pods Ready → exit 0

  if ELAPSED >= 120:
    STUCK = stuck helm-install-rke2-coredns pods (existing awk filter)
    if STUCK not empty:
      # R2: Cordon NotReady/Unknown CP nodes (single label-selector query) [NEW]
      NOTREADY_CPS = kubectl get nodes -l control-plane=true
                     | filter for status != Ready AND status != (empty/initializing)
      for each NODE in NOTREADY_CPS:
        echo "Cordoning NotReady/Unknown CP node: $NODE"
        kubectl cordon $NODE (--request-timeout=15s)
      force-delete all STUCK pods (existing, add --request-timeout=15s)

  # R3: Reset Job backoff at 300s mark (replaces FORCE_DELETE_COUNT) [NEW]
  if ELAPSED -eq 300:
    kubectl delete job helm-install-rke2-coredns --ignore-not-found=true (--request-timeout=15s)
    echo "Deleted CoreDNS installer Job to reset backoff counter"

  sleep POLL_INTERVAL; ELAPSED++
```

Key changes from original plan:
- No `FORCE_DELETE_COUNT` counter
- Cordon uses label-selector on CP nodes, not per-stuck-pod node lookup
- Job reset is at fixed `ELAPSED -eq 300`, not after N force-delete cycles
- `--request-timeout=15s` on all new kubectl calls

## Implementation Units

> **Parallelism note:** Units 1 and 2 touch independent files with no shared state and can be
> implemented concurrently by separate agents. Unit 3 (testing) runs after both complete.

---

- [ ] **Unit 1 (Agent A): Enhance etcd-recovery.sh to clear member dir**

**Goal:** Extend `rke2-etcd-recovery.sh` so that when it kills an orphaned etcd process, it also
removes the etcd member directory. This prevents the TLS handshake failure that persists when
stale multi-node WAL state remains after the orphan kill.

**Requirements:** R1

**Dependencies:** None

**Files:**
- Modify: `modules/node-pool/templates/cp-init.yaml.tpl` (lines 18–32, the
  `rke2-etcd-recovery.sh` content block)

**Approach:**
- Declare `MEMBER_DIR="/var/lib/rancher/rke2/server/db/etcd/member"` as a variable at the top
  of the script (outside the `if` block, so it is always set).
- Inside the existing `if [ -n "$ETCD_PID" ]` block, after `kill -9` and `sleep 2`, add an
  `if [ -d "$MEMBER_DIR" ]` check. If the dir exists, `rm -rf "$MEMBER_DIR"` and echo a
  success/cleared message; else echo a "member dir absent, nothing to clear" message.
- Do NOT use `|| true` on the `rm -rf` — use a branch (`&& echo "cleared" || echo "WARNING:
  could not clear member dir"`) so the outcome is always logged to the systemd journal.
- Do NOT include a backup step — YAGNI (see Key Technical Decisions).
- No structural changes to the `write_files` YAML block, the systemd drop-in, or `runcmd`.

**Patterns to follow:**
- `modules/node-pool/templates/cp-init.yaml.tpl` lines 18–32 (existing script structure and
  echo-based logging pattern)
- `|| true` guard on the `kill -9` step (existing) — mirror this style but use explicit
  success/failure branches on the `rm -rf` for visibility

**Test scenarios:**
- Orphan etcd running, member dir present: script kills etcd, removes `$MEMBER_DIR`, logs
  "member dir cleared". rke2-server starts; etcd bootstraps as fresh single-node.
- Orphan etcd running, member dir absent (e.g., fresh VM, etcd never ran): script kills etcd,
  logs "member dir absent, nothing to clear". No error. rke2-server starts normally.
- No orphan etcd (normal graceful restart): pgrep returns empty, `if [ -n "$ETCD_PID" ]` is
  false, entire block is skipped — member dir untouched.
- `rm -rf` fails (permissions, read-only filesystem): failure branch logs a WARNING; rke2-server
  still starts (the failed rm is not in `set -e` scope). Operator sees the warning in the journal.
- `MEMBER_DIR` is a symlink: `rm -rf` on a symlink without trailing slash removes the symlink
  only (not the target). This is safe.

**Verification:**
- Template renders valid YAML: no indentation errors in the `write_files` content block.
- Script body is syntactically valid bash (shell check or manual review).
- `if [ -n "$ETCD_PID" ]` guard still wraps all kill + cleanup logic — member dir is never
  cleared unless an orphan was detected.
- All `cp` / `rm` references use `$MEMBER_DIR` (absolute), not `member` (relative).
- The `MEMBER_DIR` variable is declared before the `if [ -n "$ETCD_PID" ]` block.

---

- [ ] **Unit 2 (Agent B): Enhance wait_for_coredns with node cordon and Job reset**

**Goal:** Extend the `wait_for_coredns` provisioner bash script to: (a) cordon NotReady/Unknown
CP nodes after stuck installer pods are detected; and (b) delete the `helm-install-rke2-coredns`
Job at the 300s elapsed mark to reset exponential backoff.

**Requirements:** R2, R3

**Dependencies:** None

**Files:**
- Modify: `modules/addons/coredns_wait.tf` (the `command = <<-EOT ... EOT` block inside
  `null_resource.wait_for_coredns`)

**Approach:**

*R2 — Cordon NotReady/Unknown CP nodes (inside the `ELAPSED -ge 120` + `STUCK not empty` branch):*
- Issue a single `kubectl get nodes -l node-role.kubernetes.io/control-plane=true --no-headers
  -o custom-columns=NAME:.metadata.name,READY:.status.conditions[-1].status` (or equivalent
  approach that returns node name + Ready status in one call) with `--request-timeout=15s`.
- Filter the output for lines where status is `False` or `Unknown` (not empty — an empty status
  means the node has not yet reported a condition and is still initializing; do not cordon).
- For each NotReady/Unknown node: emit `echo "  Cordoning NotReady/Unknown CP node: $NODE"` to
  stdout (visible in `terraform apply` output), then `kubectl cordon "$NODE"` with
  `--kubeconfig "$KUBECONFIG_PATH" --request-timeout=15s 2>/dev/null || true`.
- Add `--request-timeout=15s` to the existing `kubectl get pods` stuck-pod detection call too.

*R3 — Job reset at elapsed threshold (at the level of the main while loop, outside the STUCK
branch):*
- After the `ELAPSED -ge 120` + STUCK block, add: `if [ "$ELAPSED" -eq 300 ]; then kubectl
  --kubeconfig "$KUBECONFIG_PATH" delete job helm-install-rke2-coredns -n kube-system
  --ignore-not-found=true --request-timeout=15s 2>/dev/null || true; echo "  Deleted CoreDNS
  Job at ${ELAPSED}s to reset backoff counter"; fi`
- The `--ignore-not-found=true` makes this idempotent (safe if Job already gone).
- `ELAPSED -eq 300` fires once per provisioner run. If the provisioner is re-run (due to Ctrl+C,
  etc.), ELAPSED restarts from 0 — fine, the Job deletion fires again at 300s of the new run.

*Existing logic to preserve unchanged:*
- `KUBECONFIG_PATH` empty-check early-exit guard
- `MAX_WAIT=600`, `POLL_INTERVAL=10`, `ELAPSED=0` initialization
- `kubectl wait` CoreDNS Ready check (primary polling path)
- `kubectl get pods` + awk stuck-pod detection (add `--request-timeout=15s` to the get call)
- `xargs` force-delete call (keep as-is; existing `|| true` is correct)
- `null_resource.wait_for_coredns` `trigger` and `depends_on` are unchanged

**Patterns to follow:**
- `modules/addons/coredns_wait.tf` lines 31–83 (full existing provisioner structure)
- Existing `--kubeconfig "$KUBECONFIG_PATH" 2>/dev/null || true` guard style

**Test scenarios:**
- One CP node NotReady with stuck installer pod: node is cordoned (echo appears in apply output);
  pod is force-deleted; replacement spawns on a Ready CP node; CoreDNS becomes Ready.
- All CP nodes Ready, pod stuck for unrelated reason (slow kubelet): CP node query returns empty
  NotReady list; no cordon; pod is force-deleted normally.
- Pod in Pending state with no node assignment (spec.nodeName empty): label-selector approach
  correctly ignores pod's node assignment and cordons based on node status, not pod assignment.
  A Pending pod with no assigned node means no specific node is at fault — no cordon if all
  CP nodes are Ready.
- Node already cordoned when cordon runs: `kubectl cordon` returns "already cordoned" with exit 0
  — no error, no special handling needed.
- Node does not exist when cordon runs (race: node deleted between get and cordon): kubectl exits
  1, `|| true` absorbs it, loop continues.
- `ELAPSED -eq 300` fires when CoreDNS is still not ready: Job is deleted; HelmChart controller
  recreates it within seconds; fresh pod spawns; CoreDNS eventually becomes Ready.
- `ELAPSED -eq 300` fires after CoreDNS became Ready (loop already exited at exit 0): this code
  path is unreachable — the loop exits on success before reaching 300s.
- `KUBECONFIG_PATH` is empty (subsequent apply, DNS already running): provisioner exits 0 at the
  early-exit guard — all new logic is unreachable.
- API server hung during `kubectl get nodes`: `--request-timeout=15s` bounds the call; after 15s
  kubectl exits with error, `|| true` absorbs it, loop continues to next poll cycle.
- ELAPSED undercount: when the cordon loop takes >10s due to slow API, the while loop body
  exceeds the poll interval. ELAPSED still increments by POLL_INTERVAL=10 after `sleep 10`.
  This means ELAPSED undercounts actual wall time — the 300s trigger fires slightly later than
  300s wall. This is acceptable (grace, not deadline).

**Verification:**
- `terraform fmt` passes on `coredns_wait.tf` with no diff.
- `terraform validate` passes in the `modules/addons` context.
- Early-exit guard (`if [ -z "$KUBECONFIG_PATH" ]`) is intact before all kubectl calls.
- No kubectl call in the new logic is missing `--kubeconfig "$KUBECONFIG_PATH"`.
- All new kubectl calls carry `--request-timeout=15s`.
- Existing `kubectl get pods` stuck-pod detection call has `--request-timeout=15s` added.
- `null_resource.wait_for_coredns` `trigger` and `depends_on` are unchanged.
- No `FORCE_DELETE_COUNT` variable anywhere in the script.
- `ELAPSED -eq 300` guard is inside the main while loop but outside the `ELAPSED -ge 120` block.
- Cordon command emits an `echo` to stdout with the node name.

---

- [ ] **Unit 3 (Agent C / Testing): Static validation and version bump**

**Goal:** Validate that both modified files are correct and consistent, then cut v0.4.19.

**Requirements:** All (R1, R2, R3, success criteria)

**Dependencies:** Unit 1 and Unit 2 complete

**Files:**
- Read + validate: `modules/node-pool/templates/cp-init.yaml.tpl`
- Read + validate: `modules/addons/coredns_wait.tf`
- Read + validate: `modules/addons/ccm.tf` (confirm CCM `depends_on` is unchanged)
- Modify: `CHANGELOG.md` (add v0.4.19 entry)

**Approach:**
- Read both implementation files in full and verify the checklist below.
- Confirm `ccm.tf` `depends_on` still references only `kubernetes_secret_v1.hcloud_ccm[0]` and
  `helm_release.cilium` — the bootstrap deadlock fix from v0.4.18 must not be disturbed.
- Update CHANGELOG with v0.4.19 entry covering R1 and R2/R3 fixes, plus the cordon persistence
  operational note.
- Tag the module as `v0.4.19` after CHANGELOG is updated.

**Test scenarios (static validation checklist):**

Unit 1 (`cp-init.yaml.tpl`):
- [ ] `MEMBER_DIR` variable declared as absolute path before the `if [ -n "$ETCD_PID" ]` block
- [ ] All `cp`/`rm` operations reference `$MEMBER_DIR`, not the relative string `member`
- [ ] No backup step (`cp -r`) present — YAGNI, removed in deepen
- [ ] Member dir clear is inside `if [ -n "$ETCD_PID" ]` block — never at top level
- [ ] `rm -rf` uses explicit outcome logging (not silent `|| true`)
- [ ] YAML indentation of `write_files` content block is correct (no tab/space mix)
- [ ] No changes outside the `rke2-etcd-recovery.sh` content block

Unit 2 (`coredns_wait.tf`):
- [ ] `FORCE_DELETE_COUNT` does NOT appear anywhere in the script
- [ ] All new kubectl calls include `--kubeconfig "$KUBECONFIG_PATH"`
- [ ] All new kubectl calls include `--request-timeout=15s`
- [ ] Existing `kubectl get pods` stuck-pod detection call has `--request-timeout=15s` added
- [ ] Cordon uses label-selector query (`-l node-role.kubernetes.io/control-plane=true`), not
      per-pod jsonpath lookup
- [ ] Cordon filters for `False` or `Unknown` node status only (not empty)
- [ ] Cordon emits echo with node name to stdout before the kubectl cordon call
- [ ] `kubectl cordon "$NODE"` uses double-quoted variable
- [ ] Job delete is at `ELAPSED -eq 300` guard inside main loop, outside `ELAPSED -ge 120` block
- [ ] Job delete uses `--ignore-not-found=true` and `--request-timeout=15s`
- [ ] Job delete emits echo to stdout
- [ ] Early-exit guard (kubeconfig_path null check) is intact before all new logic
- [ ] `null_resource.wait_for_coredns` `trigger` and `depends_on` are unchanged
- [ ] `terraform fmt` produces no diff

CCM invariant:
- [ ] `ccm.tf` `depends_on` references `helm_release.cilium` and `kubernetes_secret_v1.hcloud_ccm[0]`
      — no reference to `null_resource.wait_for_coredns`

**Verification:**
- All checklist items pass.
- `terraform fmt -recursive` produces no diff on the modules directory.
- CHANGELOG entry for v0.4.19 is present, accurate, and includes the cordon persistence note.

---

## System-Wide Impact

- **Interaction graph:** `wait_for_coredns` is in the critical path between Cilium and CSI. CCM
  runs in parallel with it (v0.4.18 fix). The plan adds cluster state mutation (node cordoning)
  from within this provisioner. Cordoned nodes persist after Terraform completes; they are not
  tracked in Terraform state. Operators who do not read CHANGELOG may be surprised to find
  unschedulable CP nodes after a bootstrap failure recovery.
- **Error propagation:** All new kubectl calls use `|| true` — failures are logged but do not
  abort the provisioner. The 600s timeout is the outer boundary. Hung API server calls are bounded
  by `--request-timeout=15s`.
- **State lifecycle risks:** A cordoned node persists after `terraform destroy` if the cluster API
  is still reachable during destroy (benign — nodes are being destroyed anyway). The etcd member
  dir is removed from the server's filesystem; when the Hetzner server is deleted, the disk is
  wiped. No state persists beyond the server's lifetime.
- **API surface parity:** No new module variables, outputs, or interfaces are added.
- **Integration coverage:** The existing e2e V1–V7 test suite (deploy → validate → destroy) is
  the primary integration gate. A fresh 3-CP deploy with an intentionally broken joiner CP is the
  key scenario that cannot be verified via static analysis alone.

## Risks & Dependencies

- **Bootstrap scope: etcd member dir clear on stable 3-CP clusters** (HIGH priority):
  `rke2-etcd-recovery.sh` has no way to distinguish bootstrap-time crashes from operational
  crashes on a stable 3-CP cluster. If CP-0 crashes with an orphaned etcd on a running 3-CP
  cluster, clearing the member dir promotes CP-0 to a new single-node etcd cluster. CP-1 and
  CP-2 become permanently unable to rejoin without manual `rke2 server --cluster-reset` on each.
  *Mitigation for v0.4.19*: Document clearly in CHANGELOG and README that this script is designed
  for bootstrap scenarios; operators using the module for ongoing cluster management should be
  aware of this behavior. *Future work (v0.5+)*: Consider a module variable
  `etcd_auto_clear_member_dir = false` (opt-in) or timestamp-based detection of stable clusters.

- **Cordon not tracked by Terraform** (MEDIUM priority):
  A cordoned node is cluster state that Terraform writes but cannot read back or undo. If a
  bootstrap failure triggers auto-cordon and the operator later re-runs `terraform apply`, the
  provisioner will exit quickly (CoreDNS already running) without uncordoning the node. The node
  remains unschedulable. *Mitigation*: Document in CHANGELOG and README: after bootstrap failure
  recovery, run `kubectl get nodes` and `kubectl uncordon <node>` on any nodes that show
  `SchedulingDisabled`.

- **`kubectl cordon` RBAC dependency** (LOW priority):
  The kubeconfig used by the provisioner must have `nodes` patch/update permissions. If a
  restricted kubeconfig is used, cordon silently fails via `|| true`. *Mitigation*: The cordon
  `echo` to stdout makes the attempt visible; a failure leaves the node uncordoned (safe — the
  script continues to the force-delete and Job reset paths).

- **No runtime verification in this plan**: The label-selector cordon logic and the Job deletion
  behavior can only be fully verified against a live cluster. Unit 3 covers static checks; a
  follow-up e2e run (v0.4.19) is the final gate.

- **ELAPSED undercount with slow API server** (LOW priority):
  If per-CP cordon kubectl calls each take several seconds, the while loop body exceeds
  `POLL_INTERVAL`. `ELAPSED` increments by 10 after each `sleep 10` regardless — it counts poll
  cycles, not wall time. The 300s Job-deletion threshold fires later than 300s of wall clock. This
  extends recovery time only; it does not cause incorrect behavior.

## Documentation / Operational Notes

- **CHANGELOG.md v0.4.19**: Cover R1 (etcd member dir clear), R2/R3 (cordon + Job reset), plus:
  - Cordon persistence warning: "If bootstrap recovery cordons a CP node, run
    `kubectl uncordon <node>` after the cluster stabilizes."
  - etcd member dir behavior on 3-CP clusters: "On a 3-CP cluster, clearing CP-0's member dir
    creates a new single-node etcd. CP-1/CP-2 cannot rejoin automatically."
- **README / module docs**: Add a `## Operational Notes` section noting the cordon behavior and
  the etcd member dir scope limitation.
- **Consumer workspaces** (e.g., `terraform-control/rke2-poc/main.tf`): bump `?ref=v0.4.19`.

## Sources & References

- **Origin document:** [docs/brainstorms/2026-03-23-cp-bootstrap-reliability-requirements.md](docs/brainstorms/2026-03-23-cp-bootstrap-reliability-requirements.md)
- etcd-recovery script: `modules/node-pool/templates/cp-init.yaml.tpl` lines 18–32
- CoreDNS wait provisioner: `modules/addons/coredns_wait.tf`
- CCM deadlock fix (must not regress): `modules/addons/ccm.tf` line 67
- e2e findings memory: `.claude/projects/.../memory/project_e2e_test_findings.md` (issues #10, #13, #15)
- Kubernetes Job backoff source: `pkg/controller/job/job_controller.go`; `DefaultJobPodFailureBackOff=10s`, `MaxJobPodFailureBackOff=10m`; first failure has no delay; delete+recreate resets counter
- kubectl cordon source: `kubectl/pkg/drain/cordon.go`; sets `spec.unschedulable: true`; idempotent; node-not-found exits 1
- HelmChart controller: `k3s-io/helm-controller/pkg/controllers/chart/chart.go`; event-driven; no resync period; deleted Job recreated within seconds
- etcd member dir: [etcd v3.5 persistent storage](https://etcd.io/docs/v3.5/learning/persistent-storage-files/); `member/wal/*.wal`, `member/snap/db`; empty dir = fresh bootstrap
- RKE2 backup/restore: [docs.rke2.io/datastore/backup_restore](https://docs.rke2.io/datastore/backup_restore); `rke2 server --cluster-reset` is the canonical recovery path
