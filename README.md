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

```bash
# Generate scaffold for new service
./scripts/generate-service-scaffold.sh my-new-service ghcr.io/my-org

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
