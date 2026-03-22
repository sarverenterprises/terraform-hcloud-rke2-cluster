---
date: 2026-03-21
topic: argocd-addon
---

# Argo CD + Argo Rollouts Add-on

## Problem Frame

The module currently offers Flux CD as its only GitOps option. Some teams prefer
Argo CD's pull-based model and UI-driven workflow, or want both tools running
simultaneously (e.g. Flux managing infra, Argo CD managing apps). Adding Argo CD
as an independent, opt-in add-on gives operators a first-class alternative without
forcing a choice.

## Requirements

- R1. A new `enable_argocd` flag (default `false`) installs Argo CD and Argo
  Rollouts when set to `true`. Both are treated as a unit — Rollouts is always
  co-installed with Argo CD; there is no separate Rollouts flag.
- R2. `enable_argocd` and `enable_flux` are fully independent — either, both, or
  neither may be enabled on the same cluster.
- R3. Argo CD is configured with Dex for SSO. When `argocd_github_client_id` and
  `argocd_github_client_secret` are provided, the GitHub OAuth connector is
  activated automatically. When `argocd_dex_connectors` (raw Dex connectors
  config) is set, it overrides the auto-wired GitHub connector, allowing any Dex
  provider (Google, LDAP, OIDC, etc.).
- R4. An Ingress to the Argo CD UI is created only when `argocd_hostname` is set,
  using Traefik (same pattern as `grafana_hostname`). If the variable is null, no
  Ingress is created and access is via `kubectl port-forward`.
- R5. The module installs Argo CD and Rollouts only — it does not create any
  Application or ApplicationSet resources. Initial app wiring is left to the
  operator.
- R6. A new `argocd_chart_version` variable (with a pinned default) controls the
  Argo CD Helm chart version. Same pattern as other chart version variables.

## Success Criteria

- `enable_argocd = true` on a fresh cluster deploys Argo CD and Argo Rollouts
  with no errors via `terraform apply`.
- Argo CD UI is reachable at `argocd_hostname` (when set) through the Traefik
  ingress with a valid TLS cert (when cert-manager is also enabled).
- GitHub SSO login works when `argocd_github_client_id` + `argocd_github_client_secret`
  are provided.
- `enable_flux = true` and `enable_argocd = true` together produce no conflicts —
  both controllers run in the cluster simultaneously.
- Argo Rollouts controller is running and its CRDs are available to reference in
  workloads.

## Scope Boundaries

- Argo Workflows and Argo Events are out of scope.
- Argo CD Image Updater is out of scope.
- No app-of-apps or Application bootstrap — install only.
- Flux is not deprecated or marked legacy.
- No Argo CD RBAC policy configuration in the module (operator manages this
  post-deploy via Application or ConfigMap).

## Key Decisions

- **Rollouts bundled with Argo CD**: Rollouts is a natural companion to Argo CD
  and lightweight enough to always include. A separate flag would add variable
  surface with little benefit.
- **Independent from Flux**: Both tools can serve different scopes in the same
  cluster. Forcing mutual exclusivity would reduce module utility.
- **Dex for SSO, not static password**: Dex ships as part of the Argo CD chart.
  GitHub connector is the right default given `github_token` is already a concept
  in this module. Raw override preserves flexibility.
- **Install-only, no bootstrap**: Keeps module scope tight. Argo CD bootstrap is
  highly opinion-dependent (repo structure, app-of-apps vs ApplicationSet, etc.).

## Dependencies / Assumptions

- Argo CD Ingress with TLS assumes `enable_ingress = true` (Traefik) and
  `enable_cert_manager = true` are also set when `argocd_hostname` is provided.
  Module should warn but not hard-fail if they're absent.
- GitHub OAuth App must be created by the operator before applying — the module
  cannot create OAuth Apps via the GitHub API. `argocd_github_client_id` and
  `argocd_github_client_secret` must be supplied as sensitive variables.

## Outstanding Questions

### Deferred to Planning

- [Affects R1][Needs research] Which Helm chart source for Argo CD? (`argo/argo-cd`
  from `https://argoproj.github.io/argo-helm` is standard — confirm it's still
  maintained and up to date.)
- [Affects R1][Needs research] Which Helm chart for Argo Rollouts? (`argo/argo-rollouts`
  from the same repo — confirm namespace convention (`argo-rollouts` is standard).
- [Affects R3][Technical] `argocd_dex_connectors` type: should it be `string`
  (raw YAML injected into Dex config) or `list(object)` for structured input?
  Raw YAML string is simpler and more flexible for varied Dex connector types.
- [Affects R4][Technical] Argo CD Helm chart supports both `server.ingress` and
  the newer `global.networkPolicy` patterns — confirm which ingress values path
  to use for Traefik compatibility.

## Next Steps

→ `/ce:plan` for structured implementation planning
