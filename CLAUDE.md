# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is a Kubernetes GitOps manifests repository built around Argo CD and Kustomize.

- `argocd/` contains the Argo CD bootstrap objects: the root application, the `ApplicationSet`, Argo projects, and notification config.
- `bases/` is intended for environment-agnostic service manifests. The `ApplicationSet` discovers services from `bases/*`.
- `environments/` contains environment overlays. `dev/` and `staging/` own shared namespace-level resources and list per-service overlays; `production/` aggregates production service overlays.
- `components/` contains reusable Kustomize components that patch Deployments for common labels, observability annotations, and hardening.
- `scripts/` contains local helpers for scaffold generation, manifest validation, and Argo CD sync checks.

## Common commands

### Build and inspect manifests

Build a whole environment overlay:

```bash
kustomize build environments/dev
kustomize build environments/staging
kustomize build environments/production
```

Build a single service overlay once a service directory exists:

```bash
kustomize build environments/dev/<service>
kustomize build environments/staging/<service>
kustomize build environments/production/<service>
```

### Validate manifests locally

Run the repo validation script:

```bash
./scripts/validate-all-manifests.sh
```

Run the same checks CI runs for a single overlay:

```bash
kustomize build environments/dev | kubeconform -strict -kubernetes-version 1.28.0
```

Run the same checks CI runs for every overlay:

```bash
find environments/ -name "kustomization.yaml" -exec dirname {} \; | while read dir; do
  kustomize build "$dir" > /dev/null
  kustomize build "$dir" | kubeconform -strict -kubernetes-version 1.28.0
done
```

Run the Checkov scan used by CI:

```bash
checkov -d environments/ --framework kubernetes --config-file checkov.yml
```

### Generate manifests for a new service

```bash
./scripts/generate-service-scaffold.sh <service-name> <registry>
```

This script creates:

- `bases/<service>/` with the base Deployment, Service, Ingress, HPA, ExternalSecret, and Kustomization
- `environments/dev/<service>/`, `environments/staging/<service>/`, and `environments/prod/<service>/` overlays with environment-specific patches
- updates to the top-level environment `kustomization.yaml` files

### Check Argo CD sync status

```bash
./scripts/sync-status-check.sh
```

This script expects `kubectl` access to a cluster with the Argo CD `Application` CRD installed.

## High-level architecture

### Argo CD bootstrap flow

`argocd/applications/root-app.yaml` points Argo CD back at `argocd/applications` in this repo. That directory contains `app-set.yaml`, which is the main deployment engine for application manifests.

The `ApplicationSet` uses a matrix generator:

1. a fixed list of environments (`dev`, `staging`, `prod`) with per-environment sync policy and destination settings
2. git directory discovery over `bases/*`

For each discovered service/environment pair, it creates an Argo CD `Application` whose source path is `environments/{{env}}/{{path.basename}}`.

### How manifest composition works

The intended layering is:

1. service base manifests live in `bases/<service>/`
2. those bases include shared Kustomize components from `components/`
3. each environment overlay patches the base for image tag, resource sizing, ingress host, replica count, and env-specific settings
4. top-level environment `kustomization.yaml` files aggregate the service overlays plus any shared environment resources

The reusable components currently do three things:

- `components/common-labels` adds `managed-by=argocd` and `gitops=true`
- `components/observability` adds Prometheus scrape annotations and OpenTelemetry sidecar injection annotations to Deployments
- `components/security-hardening` applies pod/container security context defaults such as `runAsNonRoot`, `seccompProfile`, no privilege escalation, read-only root filesystem, and dropped capabilities

### Environment model

`dev` and `staging` are modeled as shared namespaces. Their top-level overlays include namespace-scoped shared resources such as `Namespace`, `ResourceQuota`, `LimitRange`, and `NetworkPolicy`, then list each service overlay as a resource.

Production is modeled differently: each service overlay is expected to own its own namespace-scoped resources, such as namespace creation, quota, limit range, network policy, and disruption budget, before pulling in the service base.

### Notifications

`argocd/notifications/slack-notifications.yaml` defines sync success/failure templates. The `ApplicationSet` template subscribes generated applications to the `deployments` Slack channel on sync success via annotation.

## Repo-specific gotchas

Several bootstrap files are not fully aligned right now. Verify the intended convention before making Argo CD or overlay changes:

- `root-app.yaml` points at branch `main`, while `app-set.yaml` uses `master`
- the `ApplicationSet` environment list uses `prod`, while the checked-in top-level environment directory is `environments/production`
- `apps-project.yaml` allows destinations like `dev-*` and `staging-*`, while the checked-in top-level overlays use shared namespaces `dev` and `staging`
- `README.md` mentions a `platform/` directory, but it is not present in the repo

Do not assume one of these is already canonical; inspect the related Argo CD and Kustomize files together before changing only one side of the flow.

## Current repository state

At the moment the repository contains the top-level Argo CD/bootstrap structure, Kustomize components, validation config, and scaffold scripts, but no checked-in service directories under `bases/`. If you are adding the first real service manifests, expect to touch both `bases/` and the environment overlays together.

<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan
<!-- SPECKIT END -->
