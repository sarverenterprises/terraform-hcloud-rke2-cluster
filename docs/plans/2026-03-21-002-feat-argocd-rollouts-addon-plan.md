---
title: "feat: Add Argo CD + Argo Rollouts Add-on"
type: feat
status: active
date: 2026-03-21
origin: docs/brainstorms/2026-03-21-argocd-addon-requirements.md
---

# feat: Add Argo CD + Argo Rollouts Add-on

## Overview

Add `enable_argocd` as an independent GitOps add-on that installs Argo CD and Argo
Rollouts via Helm. Mirrors the `enable_flux` / `enable_monitoring` pattern throughout the
module. Operators can run Flux and Argo CD simultaneously (e.g. Flux manages infra,
Argo CD manages apps) — neither is deprecated or made legacy.

## Problem Statement / Motivation

The module currently offers Flux CD as its only GitOps option. Some teams prefer
Argo CD's UI-driven workflow and pull-based GitOps model. Others want both tools in
the same cluster serving different scopes. There is no way to deploy Argo CD today
without bypassing the module entirely (see origin: `docs/brainstorms/2026-03-21-argocd-addon-requirements.md`).

## Proposed Solution

A new `modules/addons/argocd.tf` file follows the established 4-section pattern
(namespace → secret → helm release per component). Two Helm releases: one for
`argo/argo-cd` (in the `argocd` namespace) and one for `argo/argo-rollouts` (in
`argo-rollouts`). New variables propagate from the root module through to the
addons module, identical to how `enable_flux` and `grafana_hostname` are wired.

## Resolved Deferred Questions

The following questions from the origin brainstorm were answered during research
and spec-flow analysis, and are incorporated as decisions here:

- **Helm chart sources** (was deferred): `argo/argo-cd` and `argo/argo-rollouts`
  from `https://argoproj.github.io/argo-helm` — actively maintained, current
  stable versions `argo-cd: 9.4.15` (app `v3.3.4`) and `argo-rollouts: 2.40.8`
  (app `v1.9.0`).
- **Argo CD chart version** (was deferred): pin default to `"~> 9.4"`.
- **Argo Rollouts chart version** (was deferred): separate variable
  `argo_rollouts_chart_version`, default `"~> 2.40"`.
- **`argocd_dex_connectors` type** (was deferred): `string` (nullable, raw YAML
  heredoc). Raw YAML is simpler and covers all Dex connector types without a
  bespoke schema. When set, it replaces the auto-wired GitHub connector entirely.
- **Ingress values path for Traefik** (was deferred): use `server.ingress.*` with
  `ingressClassName = "traefik"` and `hostname = var.argocd_hostname` (chart v9.x
  uses `hostname`, not `hosts`). Argo CD server insecure mode is set via
  `configs.params."server.insecure" = "true"` (string — chart v7+ convention,
  NOT the deprecated `server.extraArgs = ["--insecure"]`).
- **Dex `clientSecret` handling** (research finding): Argo CD Dex connectors use
  a `$key` sigil to reference values from the `argocd-secret` Kubernetes Secret.
  The GitHub `clientSecret` field must be set to `$dex.github.clientSecret`, and
  a Kubernetes Secret named `argocd-secret` in the `argocd` namespace must carry
  the key `dex.github.clientSecret`. Embedding the raw secret value directly in
  the `dex.config` YAML is not supported. This requires a `kubernetes_secret_v1`
  resource for the OAuth credentials (Section 2 in the file layout below).
- **`dex.config` format** (research finding): the `configs.cm."dex.config"` value
  is a **raw YAML heredoc string** embedded in the ConfigMap — not a nested
  Terraform object. Use `templatefile` or heredoc interpolation, not `yamlencode`
  for the inner connector block.
- **Initial admin password**: when SSO is not configured, Argo CD generates an
  initial admin password in the `argocd-initial-admin-secret` K8s Secret. A module
  output documents the retrieval command. We do not data-source this secret.
- **Rollouts health integration**: Argo CD 2.x+ includes built-in health checks for
  `argoproj.io/Rollout`. No `resource.customizations` override is needed.
- **`argocd_hostname` + ingress precondition**: use a Terraform `precondition` on
  the `helm_release.argocd` lifecycle so that `argocd_hostname != null` with
  `enable_ingress == false` produces a clear plan-time error.

## Technical Approach

### File Layout

| Action | Path |
|--------|------|
| **Create** | `modules/addons/argocd.tf` |
| **Edit** | `modules/addons/variables.tf` — add 7 new variables |
| **Edit** | `modules/addons/outputs.tf` — add `argocd_admin_password_hint` output |
| **Edit** | `variables.tf` (root) — add same 7 variables |
| **Edit** | `main.tf` (root) — pass new vars to `module "addons"` |

> **Key gotcha:** `argocd-secret` is Argo CD's own reserved Secret name. The module
> creates it pre-chart only when GitHub OAuth is configured (not the raw override
> path). If Argo CD's init also tries to create this secret, the existing secret
> wins — verify chart behavior on first apply. If conflicts arise, use
> `kubernetes_secret_v1` with `lifecycle { ignore_changes = [data] }` and let
> Argo CD manage it after initial creation.

### `modules/addons/argocd.tf` Structure

Follow the canonical multi-section layout from `tailscale.tf` and `flux.tf`:

```
# Section 1: Namespace — argocd
# Section 2: Namespace — argo-rollouts
# Section 3: Secret — argocd-github-oauth (conditional on GitHub creds)
#   (stores dex.github.clientSecret for Argo CD secret sigil resolution)
# Section 4: Locals — dex_config_yaml + ingress_config
# Section 5: Helm release — argocd (argo/argo-cd)
# Section 6: Helm release — argo-rollouts (argo/argo-rollouts)
```

#### Namespace resources

```hcl
resource "kubernetes_namespace_v1" "argocd" {
  count = var.enable_argocd ? 1 : 0
  metadata { name = "argocd" }
}

resource "kubernetes_namespace_v1" "argo_rollouts" {
  count = var.enable_argocd ? 1 : 0
  metadata { name = "argo-rollouts" }
}
```

#### Secret: argocd GitHub OAuth credentials

Argo CD's Dex config uses `$dex.github.clientSecret` as a sigil referencing the
`argocd-secret` K8s Secret. The raw secret value must be stored there — it cannot
be embedded directly in the `dex.config` YAML string. Create the secret
pre-chart so Dex can resolve it on first startup:

```hcl
# Only needed when GitHub OAuth is configured (not the raw override path).
resource "kubernetes_secret_v1" "argocd_github_oauth" {
  count = (var.enable_argocd &&
           var.argocd_dex_connectors == null &&
           var.argocd_github_client_id != null &&
           var.argocd_github_client_secret != null) ? 1 : 0

  metadata {
    name      = "argocd-secret"
    namespace = kubernetes_namespace_v1.argocd[0].metadata[0].name
  }

  data = {
    # Key name must match the $sigil used in dex.config
    "dex.github.clientSecret" = var.argocd_github_client_secret
  }

  depends_on = [kubernetes_namespace_v1.argocd]
}
```

#### Locals for Dex config and ingress

Mirror the `grafana_ingress` local in `monitoring.tf`. The Dex config for GitHub
uses a heredoc string so that `$dex.github.clientSecret` is a literal sigil
(dollar sign preserved), not interpolated by Terraform. Use `<<-EOT`/`EOT` with
`%{if}` directives, or a conditional ternary:

```hcl
locals {
  # Precedence: raw override > GitHub auto-wire > null (no SSO)
  # The dex.config value is a raw YAML string embedded in the ConfigMap —
  # NOT a yamlencode object. Use heredoc for the GitHub auto-wire path to
  # prevent Terraform from interpolating the $dex.github.clientSecret sigil.
  argocd_dex_config_yaml = (
    var.argocd_dex_connectors != null
    ? var.argocd_dex_connectors
    : (var.argocd_github_client_id != null && var.argocd_github_client_secret != null)
    ? <<-EOT
      connectors:
      - type: github
        id: github
        name: GitHub
        config:
          clientID: ${var.argocd_github_client_id}
          clientSecret: $dex.github.clientSecret
      EOT
    : null
  )

  # global.domain is also set so Argo CD builds correct callback URLs for Dex.
  argocd_global_domain = var.argocd_hostname != null ? var.argocd_hostname : ""
}
```

#### Helm release: argocd

```hcl
resource "helm_release" "argocd" {
  count = var.enable_argocd ? 1 : 0

  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace_v1.argocd[0].metadata[0].name
  version    = var.argocd_chart_version

  wait    = true
  atomic  = true
  timeout = 600  # many CRDs + Deployments — same generous timeout as monitoring

  lifecycle {
    precondition {
      condition     = !(var.argocd_hostname != null && !var.enable_ingress)
      error_message = "argocd_hostname requires enable_ingress = true (Traefik must be deployed to create the Ingress)."
    }
  }

  values = [
    yamlencode(merge(
      {
        global = {
          # Sets Argo CD's external URL — used by Dex for OAuth redirect URIs.
          domain = local.argocd_global_domain
        }

        crds = {
          install = true
          keep    = true
        }

        configs = merge(
          {
            params = {
              # String "true" (not bool) — chart renders this into a ConfigMap.
              # This replaces the deprecated server.extraArgs = ["--insecure"].
              # Required when Traefik terminates TLS and proxies plain HTTP to
              # the argocd-server backend.
              "server.insecure" = "true"
            }
          },
          local.argocd_dex_config_yaml != null ? {
            cm = {
              "dex.config" = local.argocd_dex_config_yaml
            }
          } : {}
        )

        dex = {
          enabled = local.argocd_dex_config_yaml != null
        }
      },
      # Ingress block — only injected when argocd_hostname is set
      var.argocd_hostname != null ? {
        server = {
          ingress = {
            enabled          = true
            ingressClassName = "traefik"
            # chart v7+/v9.x uses hostname (singular), not hosts (list)
            hostname = var.argocd_hostname
            tls      = false  # Traefik handles TLS; backend receives plain HTTP
          }
        }
      } : {}
    ))
  ]

  depends_on = [
    kubernetes_namespace_v1.argocd,
    kubernetes_secret_v1.argocd_github_oauth,
  ]
}
```

#### Helm release: argo-rollouts

Note: Argo Rollouts CRD keys are **top-level** (`installCRDs`, `keepCRDs`), unlike
the nested `crds.install` / `crds.keep` structure in the Argo CD chart.

```hcl
resource "helm_release" "argo_rollouts" {
  count = var.enable_argocd ? 1 : 0

  name       = "argo-rollouts"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-rollouts"
  namespace  = kubernetes_namespace_v1.argo_rollouts[0].metadata[0].name
  version    = var.argo_rollouts_chart_version

  wait    = true
  atomic  = true
  timeout = 300

  values = [
    yamlencode({
      # Top-level CRD flags (different schema from argo-cd chart)
      installCRDs = true
      keepCRDs    = true

      # clusterInstall = true (default) — watches Rollouts in all namespaces.
      # dashboard enabled = false (default) — lightweight; operator enables post-install.
    })
  ]

  depends_on = [kubernetes_namespace_v1.argo_rollouts]
}
```

### New Variables

Add in `modules/addons/variables.tf` under a new `# Argo CD` section (after Monitoring):

| Variable | Type | Default | Sensitive | Notes |
|----------|------|---------|-----------|-------|
| `enable_argocd` | `bool` | `false` | no | Feature flag — deploys both Argo CD and Rollouts |
| `argocd_hostname` | `string` | `null` | no | Optional ingress hostname (same pattern as `grafana_hostname`) |
| `argocd_github_client_id` | `string` | `null` | **yes** | GitHub OAuth App client ID |
| `argocd_github_client_secret` | `string` | `null` | **yes** | GitHub OAuth App client secret |
| `argocd_dex_connectors` | `string` | `null` | no | Raw Dex connectors YAML. Overrides GitHub auto-wire when set. |
| `argocd_chart_version` | `string` | `"~> 9.4"` | no | Argo CD Helm chart version |
| `argo_rollouts_chart_version` | `string` | `"~> 2.40"` | no | Argo Rollouts Helm chart version |

Exact same 7 variables go in root `variables.tf`. Group them under:
```
# =============================================================================
# Argo CD
# =============================================================================
```
and:
```
# Argo CD chart version variables (in Chart Versions section)
```

### Root Module Wiring (`main.tf`)

Add to the `module "addons"` block, following the `enable_flux` / `grafana_hostname` pattern:

```hcl
# Argo CD
enable_argocd                = var.enable_argocd
argocd_hostname              = var.argocd_hostname
argocd_github_client_id      = var.argocd_github_client_id
argocd_github_client_secret  = var.argocd_github_client_secret
argocd_dex_connectors        = var.argocd_dex_connectors
argocd_chart_version         = var.argocd_chart_version
argo_rollouts_chart_version  = var.argo_rollouts_chart_version
```

### Outputs (`modules/addons/outputs.tf`)

```hcl
output "argocd_admin_password_hint" {
  description = <<-EOT
    Retrieval command for the Argo CD initial admin password (set when SSO is not
    configured). Run after apply:
      kubectl -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath='{.data.password}' | base64 -d
    This secret is deleted once an operator changes the password via the UI or CLI.
  EOT
  value = var.enable_argocd ? "See description for kubectl command." : null
}
```

Also propagate this output from root `outputs.tf` if desired (optional — keep parity
with `flux_public_key` which is exposed in examples/full/main.tf).

## System-Wide Impact

- **Interaction graph**: `enable_argocd = true` → creates 2 namespaces → 2 Helm
  releases → Argo CD and Rollouts CRDs installed. Both Helm releases depend on their
  respective namespace resources via `depends_on`. The Argo CD release also carries
  a `lifecycle.precondition` that prevents plans where `argocd_hostname` is set
  without `enable_ingress`.
- **Error propagation**: Atomic Helm releases will roll back on failure. If the
  `precondition` is violated it surfaces at `terraform plan` time, not apply time.
- **State lifecycle risks**: No managed secrets (Argo CD manages its own
  `argocd-initial-admin-secret`). No TLS keypair resource (unlike Flux). No
  external API calls. Low rollback risk.
- **Flux coexistence**: `enable_flux` and `enable_argocd` are independent booleans
  with no shared namespaces, no shared CRDs, and no shared Helm chart names. They
  will not conflict when both are `true`.
- **Traefik ingress compatibility**: Traefik requires `--insecure` on the Argo CD
  server because Argo CD defaults to HTTPS-only and Traefik presents TLS externally.
  Without this flag, Traefik's health check against the backend will fail (gRPC/TLS
  mismatch). This is the standard Argo CD + Traefik setup.

## Acceptance Criteria

- [ ] `enable_argocd = true` on a fresh cluster deploys without errors.
- [ ] `enable_argocd = false` (default) produces no Argo CD resources.
- [ ] `enable_argocd = true` and `enable_flux = true` simultaneously produce no
  conflicts (both controllers run).
- [ ] Argo CD UI is reachable at `argocd_hostname` (when set) via Traefik ingress.
- [ ] GitHub SSO login works when `argocd_github_client_id` + `argocd_github_client_secret`
  are provided.
- [ ] `argocd_dex_connectors` string (when set) overrides the GitHub auto-wire —
  validated by checking that the GitHub connector env vars are ignored.
- [ ] Argo Rollouts controller is running and its CRDs (`Rollout`, `AnalysisRun`,
  `AnalysisTemplate`, `Experiment`) are available.
- [ ] `terraform plan` produces a clear error when `argocd_hostname != null &&
  enable_ingress == false`.
- [ ] `terraform fmt -check` passes on all new/modified files.
- [ ] `terraform validate` passes on root module and `modules/addons`.

## Dependencies & Risks

- **Ingress + cert-manager dependency**: `argocd_hostname` requires `enable_ingress =
  true` (enforced by precondition) and `enable_cert_manager = true` (documented,
  not enforced — TLS cert will simply be missing if cert-manager is absent). Same
  pattern as `grafana_hostname`.
- **GitHub OAuth App**: must be created manually by the operator before applying.
  The module cannot create OAuth Apps. `argocd_github_client_id` and
  `argocd_github_client_secret` must be provided as sensitive tfvars.
- **Argo CD chart v7.x values API**: the `server.ingress` block was unified in v7.
  Older chart versions (< 6.x) used `server.ingress.enabled` differently. The
  default `"~> 7.8"` pin is sufficient; operators overriding `argocd_chart_version`
  below 7.0 may need to adjust values.

## Implementation Order

1. Add all 7 variables to `modules/addons/variables.tf`
2. Create `modules/addons/argocd.tf`:
   - Namespaces (argocd, argo-rollouts)
   - `kubernetes_secret_v1.argocd_github_oauth` (conditional)
   - Locals (dex_config_yaml, argocd_global_domain)
   - `helm_release.argocd` with precondition
   - `helm_release.argo_rollouts`
3. Add `argocd_admin_password_hint` output to `modules/addons/outputs.tf`
4. Add 7 variables to root `variables.tf`
5. Wire into `module "addons"` block in root `main.tf`
6. Run `terraform fmt -recursive` and `terraform validate`

## Sources & References

### Origin

- **Origin document:** [docs/brainstorms/2026-03-21-argocd-addon-requirements.md](../brainstorms/2026-03-21-argocd-addon-requirements.md)
  Key decisions carried forward: Rollouts always bundled, Flux independence, Dex for SSO with GitHub default + raw override, install-only scope.

### Internal References

- Grafana ingress local pattern: `modules/addons/monitoring.tf:41-47`
- Tailscale canonical 4-section layout: `modules/addons/tailscale.tf`
- Flux 4-section layout (with null_resource): `modules/addons/flux.tf`
- Addons feature flag variables: `modules/addons/variables.tf:152-232`
- Root module addons wiring: `main.tf:196-270`
- Addons outputs pattern: `modules/addons/outputs.tf`

### External References

- Argo CD Helm chart (argo-helm): `https://argoproj.github.io/argo-helm`
- Argo CD + Traefik ingress pattern: `https://argo-cd.readthedocs.io/en/stable/operator-manual/ingress/#traefik-v22`
- Argo Rollouts Helm chart: same argo-helm repo, chart `argo-rollouts`
- Dex GitHub connector config: `https://dexidp.io/docs/connectors/github/`
