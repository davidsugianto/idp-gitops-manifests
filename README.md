# Kubernetes GitOps Repository

Centralized GitOps repository for managing all microservices deployments using ArgoCD and Kustomize.

## 🏗️ Architecture

- **ArgoCD**: GitOps continuous delivery tool for Kubernetes
- **Kustomize**: Template-free configuration customization
- **ApplicationSet**: Auto-discovery and deployment of services
- **External Secrets Operator**: Secure secret management

## 📂 Directory Structure

```text
.
├── argocd/       # ArgoCD applications and projects
├── bases/        # Base manifests (environment-agnostic)
├── environments/ # Environment-specific overlays (dev/staging/prod)
├── components/   # Reusable Kustomize components
├── platform/     # Platform infrastructure (monitoring, logging, etc)
├── scripts/      # Utility scripts
└── docs/         # Documentation
```

## 🚀 Adding a New Service

`./scripts/generate-service-scaffold.sh` is the single source of truth for scaffold generation. The GitHub Actions workflow delegates manifest generation to this script.

```bash
# Generate scaffold for new service with legacy positional args
./scripts/generate-service-scaffold.sh my-new-service ghcr.io/my-org

# Or use flags to match the GitHub workflow inputs
./scripts/generate-service-scaffold.sh \
  --service-name my-new-service \
  --image-name ghcr.io/my-org/my-new-service \
  --environments dev,staging,prod \
  --include-ingress true \
  --include-hpa true \
  --include-external-secret true \
  --secret-store-type aws \
  --secret-keys database-url,api-key \
  --port 8080 \
  --health-check-path /health \
  --readiness-check-path /ready

# Customize the generated files
# Then commit and create PR
git add .
git commit -m "feat: add my-new-service"
git push origin main
```

## 🔄 Deployment Workflow

1. Developer pushes code to application repo
2. CI builds Docker image and pushes to registry
3. CI creates PR to this repo to update image tag
4. Platform Engineer reviews and merges PR
5. ArgoCD automatically syncs changes to cluster

## 📊 Environments

- dev: Auto-sync enabled, minimal resources
- staging: Auto-sync enabled, moderate resources
- prod: Manual sync required, high availability

## 🛠️ Validation

All PRs are automatically validated:
- Kustomize build verification
- Kubernetes schema validation (kubeconform)
- Security scanning (Checkov)
