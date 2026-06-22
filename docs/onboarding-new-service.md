# Onboarding a New Service

## Quick Start

Use the automated scaffold script:

```bash
./scripts/generate-service-scaffold.sh my-new-service ghcr.io/my-org
```

Or use the flag-based form that matches the GitHub workflow:

```bash
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
```

This will create:

- Base manifests in `bases/my-new-service/`
- Environment overlays in `environments/{dev,staging,prod}/my-new-service/`

## Manual Steps

### Customize Base Manifests

- Update `deployment.yaml` with correct image name and ports
- Add environment variables
- Configure health checks

### Update External Secrets

- Configure secret paths in `external-secret.yaml`
- Ensure secrets exist in AWS Secrets Manager

### Review Environment Patches

- Adjust resource limits per environment
- Update ingress hostnames
- Configure HPA min/max replicas

### Commit and Create PR

```bash
git add .
git commit -m "feat: add my-new-service"
git push origin main
```

### Wait for ArgoCD Sync

- ArgoCD will automatically detect the new service
- Applications will be created for dev, staging, and prod
- Dev and staging will auto-sync
- Prod requires manual approval

## Checklist

- Image name updated in base kustomization
- Health check endpoints configured
- External secrets configured
- Resource limits appropriate for each environment
- Ingress hostname correct
- CI/CD pipeline configured in application repo
