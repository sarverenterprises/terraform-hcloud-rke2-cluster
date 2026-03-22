---
title: "feat: terraform-control workspaces workspace and rke2-poc setup"
type: feat
status: completed
date: 2026-03-21
---

# feat: terraform-control workspaces workspace and rke2-poc setup

## Enhancement Summary

**Deepened on:** 2026-03-21
**Research agents used:** best-practices-researcher, framework-docs-researcher, security-sentinel, architecture-strategist, deployment-verification-agent, code-simplicity-reviewer, web-research (general-purpose), data-integrity-guardian

### Key Improvements

1. **Critical bug fixed — Phase 1 target address was wrong.** Plan specified `null_resource.wait_for_cluster` but the correct target is `null_resource.fetch_kubeconfig` (which pulls in `wait_for_cluster` via `depends_on`). Without this, kubeconfig is never captured into state.

2. **Critical omission fixed — `rke2-poc/variables.tf` is mandatory.** Every `var.*` reference in `rke2-poc/main.tf` requires a corresponding variable declaration. HCP TF workspace variables supply values but cannot create declarations. Without this file, `terraform init` fails.

3. **kubeconfig-in-state mechanism fully specified.** `terraform_data` cannot capture `local-exec` output (output mirrors input only). Helm/Kubernetes providers have no `config_raw` field. The correct mechanism: `terraform_data` with `input = file(path)` + `depends_on` stores content in state; `local_sensitive_file` in the calling module reconstructs the file on Phase 2 runners for providers.

4. **TFE provider version corrected.** Use `~> 0.74` (not `>= 0.62.0`). Terraform `>= 1.11` required for `value_wo`. Add `value_wo_version` to all write-once resources for rotation support.

5. **`tfe_variable` explosion eliminated.** 15 named resources → 2 `for_each` blocks (one for regular vars, one for `value_wo` secrets). Saves ~40% LOC, more readable.

6. **`cloudflare_zone_id` placeholder trap identified.** `value_wo` cannot be updated after first apply without a taint. Remove the placeholder; use manual UI entry (same pattern as `ssh_private_key`).

7. **HCL complex type encoding clarified.** Use literal heredoc (`<<-EOT`) for `node_pools`, not `jsonencode()`. JSON colon substitution by the TFE API is undocumented and produces incorrect output for complex nested objects.

8. **Bootstrap sequence corrected.** The `cloud` block cannot be present during the very first `terraform init` if the workspace doesn't exist yet. Correct sequence: apply without cloud block → migrate state → add cloud block.

### New Considerations Discovered

- `trigger_patterns` requires leading `/` (e.g., `"/rke2-poc/**/*"`), unlike `trigger_prefixes`
- Kubeconfig staleness is a data integrity risk: cert rotation without node replacement leaves stale state with no automatic invalidation
- `auto_apply` on `rke2-poc` workspace MUST be disabled — first VCS push auto-trigger would apply full Phase 2 before Phase 1 is done
- `tfe_variable` with `value_wo` + placeholder value is a trap: once applied, it cannot be corrected via plan/apply without `terraform taint`

---

## Overview

Set up the `terraform-control` repo with two things:

1. A **workspaces workspace** (`workspaces/` folder) that uses the `hashicorp/tfe` provider to provision and manage all HCP Terraform Cloud workspaces as code — including their VCS connections, variable sets, and shared secrets.
2. A **rke2-poc workspace** (`rke2-poc/` folder) that calls the `sarverenterprises/rke2-cluster/hcloud` registry module to provision a full-stack RKE2 cluster on Hetzner.

This also requires two prerequisite changes to the **terraform-hcloud-rke2-cluster module**:
- Make `hcloud_token` optional (default `null`) so the `HCLOUD_TOKEN` env var satisfies the provider without passing a Terraform variable.
- Add kubeconfig-in-state support so that HCP TF remote execution (where local disk is ephemeral) can surface the kubeconfig via Terraform output rather than only via a local file.

## Problem Statement

The `terraform-control` repo is empty. There is no workspace-as-code system for managing HCP Terraform Cloud workspaces, and no way to automatically inject shared secrets (Hetzner token, Cloudflare API key) into child workspaces. Managing the rke2-poc cluster requires a workspace, VCS connection, and a full variable manifest — currently all manual.

The rke2 module also has two behaviors incompatible with HCP TF remote execution:
1. `hcloud_token` is a required input — forcing every workspace to carry it as a Terraform variable rather than the standard env var pattern.
2. Kubeconfig is only persisted to local disk — in HCP TF managed runners, the disk is ephemeral and the kubeconfig is gone after Phase 1 completes, blocking Phase 2 (addons).

## Proposed Solution

### Phase 0 — Module changes (terraform-hcloud-rke2-cluster)

Two targeted changes to the rke2 module before writing `terraform-control`:

**0a. Make `hcloud_token` optional**

Change `hcloud_token` to `default = null`. All providers already read `HCLOUD_TOKEN` from the environment when no explicit token is passed. The module already sets `hcloud_ccm_token`, `hcloud_csi_token`, and `hcloud_autoscaler_token` to fall back on `hcloud_token` when null — that pattern continues. This removes the need to create a `terraform`-category `tfe_variable` for `hcloud_token` in every child workspace; the `HCLOUD_TOKEN` env-category variable is sufficient.

**0b. Kubeconfig-in-state output**

Add a `kubeconfig_raw` output (sensitive) that stores the kubeconfig content directly in Terraform state. The mechanism is a `terraform_data` resource that reads the kubeconfig file into its `input` attribute immediately after `null_resource.fetch_kubeconfig` writes it (via `depends_on`). Since `terraform_data.input` is a managed resource attribute, it persists in state across all subsequent runs. The existing disk-write behavior is preserved for local use.

Calling modules (e.g., `rke2-poc/main.tf`) then use `local_sensitive_file` to write the state-persisted kubeconfig back to disk on Phase 2 runners, and configure Helm/Kubernetes providers via `config_path`.

> **Why not `config_raw`?** Neither the Helm provider nor the Kubernetes provider has a `config_raw` field that accepts an inline kubeconfig string. The Helm provider uses `host`/`cluster_ca_certificate`/`client_key`/`client_certificate` for inline creds, or `config_path` for a file. `local_sensitive_file` writing the kubeconfig back to disk is the simplest correct approach.

Release these changes as **v0.3.0** (minor version bump; removing a required input is backwards-compatible since all existing callers that pass `hcloud_token` continue to work).

### Phase 1 — workspaces workspace

The `workspaces/` folder is the control plane. It holds:
- TFE provider configuration + `cloud` backend
- Shared secret variables (HCLOUD_TOKEN, Cloudflare, TFE_TOKEN)
- One `.tf` file per managed workspace (e.g., `rke2-poc.tf`)

Each child workspace file uses two `for_each` resource blocks (not 15 named resources): one for regular variables and one for write-once (`value_wo`) secrets. Secrets shared across workspaces reference variables declared in `workspaces/variables.tf`.

### Phase 2 — rke2-poc workspace

The `rke2-poc/` folder contains `terraform.tf`, `variables.tf` (mandatory — HCP TF workspace variables supply values but not declarations), and `main.tf`. The `main.tf` calls the registry module, with Helm/Kubernetes providers configured from a `local_sensitive_file` resource that writes the state-persisted kubeconfig back to disk at Phase 2 apply time.

Two-phase apply is handled manually:
- **Phase 1**: Trigger a run in HCP TF UI with target `null_resource.fetch_kubeconfig` (this pulls in all infra dependencies via `depends_on`).
- **Phase 2**: After Phase 1 completes and `kubeconfig_raw` is in state, trigger a normal run (no target) to apply addons.

## Technical Approach

### Repo Structure

```
terraform-control/
├── workspaces/
│   ├── terraform.tf          # cloud block (sarverenterprises/workspaces) + required_providers
│   ├── variables.tf          # shared secrets: hcloud_token, cloudflare_api_token
│   ├── main.tf               # provider "tfe" + data.tfe_oauth_client
│   └── rke2-poc.tf           # tfe_workspace + 2 for_each tfe_variable resources
└── rke2-poc/
    ├── terraform.tf          # cloud block (sarverenterprises/rke2-poc) + required_providers
    ├── variables.tf          # MANDATORY: declarations for all workspace-injected vars
    └── main.tf               # module "cluster" + provider configs + local_sensitive_file
```

### workspaces/terraform.tf

> **Note on version:** `~> 0.74` is the current stable TFE provider family. Terraform `>= 1.11` is required for `value_wo`. The plan's original `>= 0.62.0` was too broad and would pick up breaking changes.

```hcl
terraform {
  cloud {
    organization = "sarverenterprises"
    workspaces {
      name = "workspaces"
    }
  }
  required_providers {
    tfe = {
      source  = "hashicorp/tfe"
      version = "~> 0.74"
    }
  }
  required_version = ">= 1.11"
}
```

> **Bootstrap caveat:** The `cloud {}` block cannot be present during the very first `terraform init` if the `workspaces` workspace does not yet exist in HCP TF. See Bootstrap Sequence for the correct two-phase init approach.

### workspaces/variables.tf

```hcl
variable "hcloud_token" {
  description = "Hetzner Cloud API token. Injected as HCLOUD_TOKEN env var into cluster workspaces."
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token (Zone:DNS:Edit). Injected as cloudflare_api_token tf var into cluster workspaces."
  type        = string
  sensitive   = true
}
```

> **`tfe_token` is NOT a Terraform variable here.** The TFE provider reads `TFE_TOKEN` from the environment directly. It is set as a sensitive env var on the workspaces workspace in the HCP TF UI (manually, during bootstrap). It never flows through a `tfe_variable` resource — that would be circular.

### workspaces/main.tf

```hcl
provider "tfe" {
  # Reads TFE_TOKEN from environment (set manually in HCP TF workspace)
}

data "tfe_oauth_client" "github" {
  organization     = "sarverenterprises"
  service_provider = "github"
}
```

### workspaces/rke2-poc.tf

This replaces 15 named `tfe_variable` resources with 2 `for_each` blocks. `value_wo` and regular `value` are mutually exclusive in the TFE provider schema — they require separate resource blocks.

```hcl
resource "tfe_workspace" "rke2_poc" {
  name              = "rke2-poc"
  organization      = "sarverenterprises"
  description       = "RKE2 proof-of-concept cluster on Hetzner Cloud (Ashburn)."
  working_directory = "rke2-poc"

  # trigger_patterns requires a leading "/" on HCP TF SaaS
  file_triggers_enabled = true
  trigger_patterns      = ["/rke2-poc/**/*"]

  vcs_repo {
    identifier     = "sarverenterprises/terraform-control"
    oauth_token_id = data.tfe_oauth_client.github.oauth_token_id
  }

  # MUST be false — first VCS push would trigger full apply before Phase 1 is done
  auto_apply = false

  lifecycle {
    prevent_destroy = true
  }
}

# ── Regular variables (plaintext or sensitive value) ─────────────────────────
# NOTE: Complex types (node_pools, ssh_keys) use hcl = true with literal HCL
# strings in <<-EOT heredocs. Do NOT use jsonencode() — the TFE API's internal
# JSON→HCL substitution is undocumented and breaks on nested objects with colons.

locals {
  rke2_poc_vars = {
    cluster_name = {
      value    = "rke2-poc"
      category = "terraform"
      hcl      = false
      sensitive = false
    }
    location = {
      value    = "ash"
      category = "terraform"
      hcl      = false
      sensitive = false
    }
    ssh_keys = {
      # Literal HCL list — must match an existing Hetzner SSH key name
      value    = <<-EOT
        ["rke2-poc"]
      EOT
      category = "terraform"
      hcl      = true
      sensitive = false
    }
    node_pools = {
      # Literal HCL list(object). Indent must match closing EOT for <<-EOT.
      value    = <<-EOT
        [
          {
            name        = "workers"
            server_type = "cpx31"
            node_count  = 2
          }
        ]
      EOT
      category = "terraform"
      hcl      = true
      sensitive = false
    }
    enable_argocd = {
      value    = "true"
      category = "terraform"
      hcl      = false
      sensitive = false
    }
    enable_ingress = {
      value    = "true"
      category = "terraform"
      hcl      = false
      sensitive = false
    }
    enable_cert_manager = {
      value    = "true"
      category = "terraform"
      hcl      = false
      sensitive = false
    }
    enable_external_dns = {
      value    = "true"
      category = "terraform"
      hcl      = false
      sensitive = false
    }
    cloudflare_zone = {
      value    = "sarvent.cloud"
      category = "terraform"
      hcl      = false
      sensitive = false
    }
    argocd_hostname = {
      value    = "argocd.rke2-poc.sarvent.cloud"
      category = "terraform"
      hcl      = false
      sensitive = false
    }
    expose_rke2_token = {
      value    = "false"
      category = "terraform"
      hcl      = false
      sensitive = false
    }
    # ssh_private_key has no value — set manually in HCP TF UI
    ssh_private_key = {
      value     = null
      category  = "terraform"
      hcl       = false
      sensitive = true
    }
    # cloudflare_zone_id has no value — set manually in HCP TF UI
    # (cannot use value_wo with a placeholder — it cannot be corrected without taint)
    cloudflare_zone_id = {
      value     = null
      category  = "terraform"
      hcl       = false
      sensitive = true
    }
  }
}

resource "tfe_variable" "rke2_poc" {
  for_each = local.rke2_poc_vars

  workspace_id = tfe_workspace.rke2_poc.id
  key          = each.key
  value        = each.value.value
  category     = each.value.category
  hcl          = each.value.hcl
  sensitive    = each.value.sensitive
}

# ── Write-once secrets (value_wo, mutually exclusive with value) ──────────────
# value_wo_version: increment this integer to rotate the secret.
# Plans will show no diff for value_wo fields — rotation is only detectable
# via HCP TF audit logs or by verifying the workspace variable in the UI.

locals {
  rke2_poc_wo_vars = {
    HCLOUD_TOKEN = {
      value_wo         = var.hcloud_token
      value_wo_version = 1
      category         = "env"
    }
    cloudflare_api_token = {
      value_wo         = var.cloudflare_api_token
      value_wo_version = 1
      category         = "terraform"
    }
  }
}

resource "tfe_variable" "rke2_poc_wo" {
  for_each = local.rke2_poc_wo_vars

  workspace_id     = tfe_workspace.rke2_poc.id
  key              = each.key
  value_wo         = each.value.value_wo
  value_wo_version = each.value.value_wo_version
  category         = each.value.category
  sensitive        = true
}
```

### rke2-poc/terraform.tf

```hcl
terraform {
  cloud {
    organization = "sarverenterprises"
    workspaces {
      name = "rke2-poc"
    }
  }
  required_providers {
    hcloud     = { source = "hetznercloud/hcloud",  version = ">= 1.58.0" }
    helm       = { source = "hashicorp/helm",        version = ">= 2.14.0" }
    kubernetes = { source = "hashicorp/kubernetes",  version = ">= 2.31.0" }
    tls        = { source = "hashicorp/tls",         version = ">= 4.0.0" }
    null       = { source = "hashicorp/null",        version = ">= 3.2.0" }
    random     = { source = "hashicorp/random",      version = ">= 3.6.0" }
    local      = { source = "hashicorp/local",       version = ">= 2.5.0" }
  }
  required_version = ">= 1.11"
}
```

> **`hashicorp/local` is required** for `local_sensitive_file` to write the kubeconfig back to disk on Phase 2 runners.

### rke2-poc/variables.tf

> **This file is mandatory.** HCP TF workspace variables supply values but cannot create Terraform variable declarations. Every `var.*` reference in `main.tf` must have a corresponding block here.

```hcl
variable "cluster_name"    { type = string }
variable "location"        { type = string }
variable "ssh_keys"        { type = list(string) }
variable "ssh_private_key" { type = string; sensitive = true }
variable "node_pools" {
  type = list(object({
    name        = string
    server_type = string
    node_count  = optional(number, 1)
    location    = optional(string)
  }))
}

variable "enable_argocd"       { type = bool;   default = false }
variable "enable_ingress"      { type = bool;   default = false }
variable "enable_cert_manager" { type = bool;   default = false }
variable "enable_external_dns" { type = bool;   default = false }
variable "expose_rke2_token"   { type = bool;   default = false }

variable "cloudflare_api_token" { type = string; sensitive = true; default = null }
variable "cloudflare_zone"      { type = string; default = null }
variable "cloudflare_zone_id"   { type = string; sensitive = true; default = null }
variable "argocd_hostname"      { type = string; default = null }
```

### rke2-poc/main.tf

```hcl
# Phase 1: Targeted apply
#   Target: null_resource.fetch_kubeconfig
#   (fetch_kubeconfig depends_on wait_for_cluster which depends_on all infra)
#   Via HCP TF UI: "Start new run" > Advanced options > target-addrs
#   Via HCP TF API: POST /api/v2/runs with {"data":{"attributes":{"target-addrs":
#     ["null_resource.fetch_kubeconfig"]},"type":"runs","relationships":{"workspace":...}}}
#
# Phase 2: Normal apply (no target)
#   kubeconfig_raw is in state from Phase 1; local_sensitive_file writes it back to disk

provider "hcloud" {
  # Reads HCLOUD_TOKEN from environment (set by workspaces workspace via tfe_variable)
}

# local_sensitive_file writes the state-persisted kubeconfig back to disk on the Phase 2 runner.
# Content is sourced from module.cluster.kubeconfig (terraform_data state output, not local file).
# On Phase 1, module.cluster.kubeconfig is null — local_sensitive_file is not created.
# On Phase 2, module.cluster.kubeconfig is the state-persisted string from Phase 1.
resource "local_sensitive_file" "kubeconfig" {
  count    = module.cluster.kubeconfig != null ? 1 : 0
  content  = module.cluster.kubeconfig
  filename = "${path.module}/.kube/${var.cluster_name}.yaml"
}

provider "helm" {
  kubernetes = {
    config_path = length(local_sensitive_file.kubeconfig) > 0 ? local_sensitive_file.kubeconfig[0].filename : ""
  }
}

provider "kubernetes" {
  config_path = length(local_sensitive_file.kubeconfig) > 0 ? local_sensitive_file.kubeconfig[0].filename : ""
}

module "cluster" {
  source  = "sarverenterprises/rke2-cluster/hcloud"
  version = "~> 0.3"  # v0.3.0 required for hcloud_token=null + kubeconfig state persistence

  # hcloud_token not passed — module reads HCLOUD_TOKEN env var (v0.3.0 feature)

  cluster_name    = var.cluster_name
  ssh_keys        = var.ssh_keys
  ssh_private_key = var.ssh_private_key
  location        = var.location
  node_pools      = var.node_pools

  # Add-ons
  enable_argocd        = var.enable_argocd
  enable_ingress       = var.enable_ingress
  enable_cert_manager  = var.enable_cert_manager
  enable_external_dns  = var.enable_external_dns

  # Cloudflare
  cloudflare_api_token = var.cloudflare_api_token
  cloudflare_zone      = var.cloudflare_zone
  cloudflare_zone_id   = var.cloudflare_zone_id

  # Argo CD
  argocd_hostname = var.argocd_hostname
}
```

## Module Changes (Phase 0)

### 0a: Make hcloud_token optional (`variables.tf`)

```hcl
# BEFORE
variable "hcloud_token" {
  description = "Default Hetzner Cloud API token."
  type        = string
  sensitive   = true
}

# AFTER
variable "hcloud_token" {
  description = "Default Hetzner Cloud API token. When null, all providers read HCLOUD_TOKEN from the environment."
  type        = string
  sensitive   = true
  default     = null
}
```

Update all providers and sub-module calls that pass `hcloud_token` to handle null gracefully (the hcloud provider auto-reads `HCLOUD_TOKEN` when no explicit token is set).

### 0b: kubeconfig-in-state (`modules/control_plane/`)

The `null_resource.fetch_kubeconfig` writes kubeconfig to `${path.root}/.kube/${var.cluster_name}.yaml`. To also capture in state:

```hcl
# modules/control_plane/kubeconfig.tf (new resource)

resource "terraform_data" "kubeconfig_store" {
  # depends_on ensures fetch_kubeconfig provisioner has run before file() is called
  depends_on = [null_resource.fetch_kubeconfig]

  # file() is evaluated at apply time (after the provisioner runs), not at plan time.
  # The result is stored in state and survives between HCP TF runs.
  # sensitive() prevents the value from appearing in plan output diffs.
  input = sensitive(file(local.kubeconfig_path))

  # Re-store when the cluster is reprovisioned (same trigger as fetch_kubeconfig)
  triggers_replace = [
    join(",", [for s in hcloud_server.nodes : s.id]),
    hcloud_load_balancer.control_plane.ipv4
  ]
}
```

> **Why `terraform_data` and not `data "local_file"`?** Data sources re-read from disk on every plan. In HCP TF remote execution, the file does not exist on subsequent runs. `terraform_data` is a managed resource — its `input`/`output` is stored in state and available on all future plans and applies without re-reading.

> **Add `certificate_rotation_id` trigger variable** to allow operators to force kubeconfig refresh after certificate rotation without replacing nodes:

```hcl
# modules/control_plane/variables.tf (new variable)
variable "certificate_rotation_id" {
  description = "Increment to force kubeconfig re-fetch after RKE2 certificate rotation."
  type        = number
  default     = 0
}
```

Update `terraform_data.kubeconfig_store.triggers_replace` to include this variable.

Propagate `kubeconfig_raw` up through module outputs:

```hcl
# modules/control_plane/outputs.tf
output "kubeconfig_raw" {
  description = "Kubeconfig contents stored in Terraform state. Available after Phase 1 apply."
  value       = terraform_data.kubeconfig_store.output
  sensitive   = true
}
```

```hcl
# outputs.tf (root module)
output "kubeconfig" {
  description = <<-EOT
    Kubeconfig file contents for connecting to the cluster.
    Sourced from Terraform state (persists across HCP TF remote runs).
    IMPORTANT: Workspace read access = cluster-admin access. Restrict accordingly.
  EOT
  value     = module.control_plane.kubeconfig_raw
  sensitive = true
}
```

> **Note on the existing `kubeconfig` output:** The current `fileexists(local.kubeconfig_path) ? file(local.kubeconfig_path) : null` pattern returns `null` on all HCP TF Phase 2 runs. Replacing it with `module.control_plane.kubeconfig_raw` (state-sourced) is a non-breaking change for local callers — the value is identical, just sourced from state instead of disk.

Also add `hashicorp/local` to root `terraform.tf` required_providers.

### Version bump

After Phase 0 changes pass `terraform validate` and `terraform fmt -recursive`:
- Bump to `v0.3.0` in documentation + CHANGELOG.md
- Tag and push `v0.3.0`

## Bootstrap Sequence

The exact order matters. Deviating causes `init` failures or auth errors.

### Step 1: Prepare repo without cloud block

Comment out the `cloud {}` block in `workspaces/terraform.tf` before the first init:

```hcl
# terraform {
#   cloud {
#     organization = "sarverenterprises"
#     workspaces { name = "workspaces" }
#   }
# ...
```

### Step 2: Create workspaces workspace manually in HCP TF UI

1. HCP TF UI → New workspace → CLI-driven (no VCS yet)
2. Name: `workspaces`, Organization: `sarverenterprises`
3. In workspace settings → Variables → add environment variable:
   - `TFE_TOKEN` = (team token with manage-workspaces permission) — **sensitive**
   - `hcloud_token` = (Hetzner API token) — sensitive, terraform category
   - `cloudflare_api_token` = (Cloudflare token) — sensitive, terraform category

### Step 3: Local apply + migrate state

```bash
cd terraform-control/workspaces

# Init without cloud block (uses local state)
terraform init

# Verify TFE provider can auth (TFE_TOKEN must be in local env for this step)
export TFE_TOKEN=<your-token>
terraform plan

# Apply — creates rke2-poc workspace + all variables in HCP TF
terraform apply
```

### Step 4: Migrate state to HCP TF

```bash
# Uncomment the cloud {} block in terraform.tf, then:
terraform init -migrate-state
# Confirm: "yes" to migrate local state to HCP TF remote backend
```

### Step 5: Configure VCS on workspaces workspace

In HCP TF UI, connect the `workspaces` workspace to VCS:
- Repository: `sarverenterprises/terraform-control`
- Working directory: `workspaces`
- Trigger patterns: `workspaces/**/*`

From this point, pushes to `workspaces/` trigger automated runs.

### Step 6: rke2-poc bootstrap

After the workspaces workspace applies (Step 3/4):

1. In HCP TF UI, open the `rke2-poc` workspace
2. Set the `ssh_private_key` variable value (sensitive) — created with no value, set it now
3. Set the `cloudflare_zone_id` variable value (sensitive) — created with no value, set it now
4. **Phase 1 run** — Click "Start new run" → Advanced options → Terraform targets:
   ```
   null_resource.fetch_kubeconfig
   ```
   This target pulls in all dependencies (networking, control_plane, worker_pools, wait_for_cluster) via `depends_on`. Apply when plan looks correct. Provisions infra + captures kubeconfig into state.
5. **Phase 2 run** — Start a new run with no target. Applies addons (Argo CD, Traefik, cert-manager, external-dns).

> **Via HCP TF API (Phase 1):**
> ```bash
> curl -X POST https://app.terraform.io/api/v2/runs \
>   -H "Authorization: Bearer $TFE_TOKEN" \
>   -H "Content-Type: application/vnd.api+json" \
>   -d '{
>     "data": {
>       "attributes": {
>         "message": "Phase 1 — infra + kubeconfig",
>         "target-addrs": ["null_resource.fetch_kubeconfig"]
>       },
>       "type": "runs",
>       "relationships": {
>         "workspace": {"data": {"type": "workspaces", "id": "ws-XXXXX"}}
>       }
>     }
>   }'
> ```

### Step 7: Retrieve kubeconfig

```bash
# Via HCP TF CLI (after configuring local Terraform with cloud block)
cd terraform-control/rke2-poc
terraform init
terraform output -raw kubeconfig > ~/.kube/rke2-poc.yaml
chmod 600 ~/.kube/rke2-poc.yaml
```

## Two-Phase Apply Reference

| Phase | Target (HCP TF) | What it provisions | Prerequisites |
|-------|----------------|--------------------|---------------|
| 1 | `null_resource.fetch_kubeconfig` | Hetzner networking, control plane, worker pools, kubeconfig captured in state | `ssh_private_key` set in UI |
| 2 | *(no target — full apply)* | Helm releases: Argo CD, Traefik, cert-manager, external-dns | Phase 1 complete, `cloudflare_zone_id` set |

> **HCP TF limitation:** `-target` cannot be configured as a workspace default. Phase 1 must always be triggered manually (UI or API `target-addrs`). Subsequent normal applies (code changes, variable updates) are all Phase 2 style and succeed because kubeconfig persists in state.

> **First VCS push risk:** The `rke2-poc` workspace has `auto_apply = false` to prevent the first automated run from attempting Phase 2 before Phase 1 has been manually triggered. Never change this to `auto_apply = true` without first confirming kubeconfig is in state.

## Variable Management Pattern

| Variable | Source | Category | Mechanism |
|---|---|---|---|
| `HCLOUD_TOKEN` | workspaces ws var `hcloud_token` | env | `tfe_variable` `value_wo` + `value_wo_version` |
| `cloudflare_api_token` | workspaces ws var `cloudflare_api_token` | terraform | `tfe_variable` `value_wo` + `value_wo_version` |
| `ssh_private_key` | Manual — HCP TF UI | terraform | `tfe_variable` `value = null` |
| `cloudflare_zone_id` | Manual — HCP TF UI | terraform | `tfe_variable` `value = null` |
| `cluster_name`, `location`, etc. | Literal in `rke2-poc.tf` locals map | terraform | `tfe_variable` for_each plaintext |
| `node_pools` | Literal HCL heredoc in locals map | terraform | `tfe_variable` for_each `hcl = true` |
| `ssh_keys` | Literal HCL list in locals map | terraform | `tfe_variable` for_each `hcl = true` |

**On `value_wo` (write-once):** Once applied, the value is not stored in state and cannot be compared in plan. Secret rotation is triggered by incrementing `value_wo_version`. Verify rotation took effect via the HCP TF audit log (the variable update event will appear even when the plan shows no diff).

**On variables with `value = null`:** The `tfe_variable` resource is created as a key with no value. The workspace will fail to apply until the value is manually set in the HCP TF UI. This is intentional for cluster-specific secrets (ssh_private_key, cloudflare_zone_id) that are too sensitive to source from the workspaces workspace's state.

**⚠️ Do NOT use `value_wo` with a placeholder string:** Once applied, `value_wo` cannot be corrected via plan/apply. The only recovery is `terraform taint tfe_variable.<name>`, which re-creates the resource. Use `value = null` (UI-managed) for variables where the real value is not yet available at workspaces-workspace apply time.

## Acceptance Criteria

- [ ] `terraform init` succeeds locally in `workspaces/` (without cloud block) and in `rke2-poc/`
- [ ] `terraform plan` in `workspaces/` shows rke2-poc workspace + all variables (0 errors)
- [ ] Workspaces workspace applies cleanly, creating `rke2-poc` workspace visible in HCP TF UI
- [ ] `rke2-poc` workspace variables populated: HCLOUD_TOKEN, cloudflare_api_token (via `value_wo`), all plaintext vars, null-value vars for ssh_private_key + cloudflare_zone_id
- [ ] After operator sets `ssh_private_key` + `cloudflare_zone_id` in UI, Phase 1 targeted apply succeeds
- [ ] `terraform output kubeconfig` from `rke2-poc` workspace returns non-null after Phase 1
- [ ] Phase 2 apply succeeds: Argo CD pods running in `argocd` namespace
- [ ] Traefik load balancer has an external IP assigned by Hetzner CCM
- [ ] `argocd_hostname` resolves via Cloudflare DNS (external-dns provisions the record)
- [ ] rke2 module v0.3.0: `hcloud_token` optional, `terraform validate` passes
- [ ] rke2 module v0.3.0: `kubeconfig` output populated in state after Phase 1

## Dependencies & Risks

| Risk | Severity | Mitigation |
|---|---|---|
| `rke2-poc/variables.tf` missing | Critical | Include in files-to-create list; without it `terraform init` fails |
| Phase 1 target wrong (wait_for_cluster vs fetch_kubeconfig) | Critical | Target is `null_resource.fetch_kubeconfig` — it depends_on wait_for_cluster |
| `value_wo` placeholder for cloudflare_zone_id | High | Use `value = null` instead; set in UI before first Phase 1 run |
| First VCS push triggers full apply before Phase 1 | High | `auto_apply = false` on rke2-poc workspace (already set) |
| kubeconfig staleness after cert rotation (no node replace) | High | Add `certificate_rotation_id` trigger variable to module |
| Kubeconfig in state = cluster-admin access for all workspace readers | Medium | Restrict workspace access; document equivalence in README |
| `value_wo` rotation invisible to plan | Medium | Use `value_wo_version` + HCP TF audit log for verification |
| `tfe_workspace` destruction if `rke2-poc.tf` is removed | Medium | `lifecycle { prevent_destroy = true }` — already in plan |
| Bootstrap cloud-block chicken-and-egg | Medium | Follow two-phase init: apply without block → migrate-state → add block |
| TFE_TOKEN scope (org vs team token) | Low | Use team token scoped to workspace management only, not org owner |

## Security Notes

From security audit (security-sentinel):

1. **TFE_TOKEN should be a team token**, not an org owner token. Scope it to workspace write + variable write permissions only.

2. **Workspace read access = cluster-admin access** once kubeconfig is in state. Treat the `rke2-poc` workspace like a root credential store.

3. **SSH host key checking (`StrictHostKeyChecking=no`)** in `fetch_kubeconfig` is an existing MITM risk — not introduced by this plan, but worth noting. If the CP node IP is recycled by Hetzner, a compromised host could poison the state-persisted kubeconfig. Consider adding host key pinning in a future module version.

4. **GitHub token in flux.tf** is interpolated inline (not via env var). This exposes it in HCP TF run logs. Fix in a separate PR: move to `environment = { GITHUB_TOKEN = var.github_token }`.

5. **Grafana hardcoded password** (`adminPassword = "changeme"`) in monitoring.tf. Remove the key entirely — chart generates a random password stored in a Kubernetes Secret.

6. **API server open to 0.0.0.0/0** by default (`kube_api_allowed_cidrs`). Override in `rke2-poc.tf` to restrict to known CIDRs.

## Files to Create/Modify

### terraform-hcloud-rke2-cluster (this repo)

| File | Change |
|---|---|
| `variables.tf` | `hcloud_token` → `default = null` |
| `modules/control_plane/kubeconfig.tf` | Add `terraform_data.kubeconfig_store` resource with `sensitive()` + `certificate_rotation_id` trigger |
| `modules/control_plane/variables.tf` | Add `certificate_rotation_id` variable (default 0) |
| `modules/control_plane/outputs.tf` | Add `kubeconfig_raw` sensitive output |
| `outputs.tf` | Replace `fileexists()`/`file()` pattern with `module.control_plane.kubeconfig_raw` |
| `terraform.tf` | Add `hashicorp/local >= 2.5.0` to required_providers |
| `CHANGELOG.md` | v0.3.0 entry |
| `examples/*/main.tf` | Add `local_sensitive_file` + update providers to use `config_path` |

### terraform-control (../terraform-control)

| File | Action |
|---|---|
| `workspaces/terraform.tf` | Create (`~> 0.74`, `>= 1.11`) |
| `workspaces/variables.tf` | Create (hcloud_token, cloudflare_api_token) |
| `workspaces/main.tf` | Create (provider "tfe" + data.tfe_oauth_client) |
| `workspaces/rke2-poc.tf` | Create (tfe_workspace + 2 for_each tfe_variable blocks) |
| `rke2-poc/terraform.tf` | Create (cloud block + required_providers incl. local) |
| `rke2-poc/variables.tf` | Create (**mandatory** — all var declarations) |
| `rke2-poc/main.tf` | Create (module call + local_sensitive_file + provider configs) |
| `README.md` | Create (bootstrap sequence summary) |

## Sources & References

### Internal

- Root `variables.tf` — full variable list for rke2 module
- `outputs.tf` — existing kubeconfig output pattern (to be replaced)
- `modules/control_plane/` — kubeconfig fetch null_resource (Phase 0b target)
- `examples/argocd/main.tf` — local provider config pattern (to be updated)

### External

- [TFE Provider v0.74 — Terraform Registry](https://registry.terraform.io/providers/hashicorp/tfe/latest/docs)
- [tfe_workspace Resource](https://registry.terraform.io/providers/hashicorp/tfe/latest/docs/resources/workspace)
- [tfe_variable Resource — `value_wo` and `value_wo_version`](https://registry.terraform.io/providers/hashicorp/tfe/latest/docs/resources/variable)
- [data.tfe_oauth_client](https://registry.terraform.io/providers/hashicorp/tfe/latest/docs/data-sources/oauth_client)
- [terraform_data resource (Terraform 1.4+)](https://developer.hashicorp.com/terraform/language/resources/terraform-data)
- [Write-only arguments — HashiCorp Developer](https://developer.hashicorp.com/terraform/language/manage-sensitive-data/write-only)
- [HCP TF Runs API — target-addrs](https://developer.hashicorp.com/terraform/cloud-docs/api-docs/run#create-a-run)
- [Bootstrap a Terraform Cloud Governance Workspace — Solliance](https://solliance.net/blog/bootstrap-terraform-cloud-governance-workspace)
- [HCL-enabled tfe_variable gotchas — Brendan Thompson](https://brendanthompson.com/hcl-enabled-tfe-variables/)
- [terraform-provider-kubernetes: config_raw feature request #1735 (open)](https://github.com/hashicorp/terraform-provider-kubernetes/issues/1735)
