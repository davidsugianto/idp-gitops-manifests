# 🎯 Workflow

## Developer Workflow:
1. Developer pushes code to the main branch in the `go-http-server` repo
2. CI builds the image and pushes it to GHCR with the `dev-latest` tag
3. CI calls the shared workflow to update `environments/dev/go-http-server/kustomization.yaml`
4. The shared workflow commits and pushes the changes to the GitOps repo
5. ArgoCD detects the changes and auto-syncs to the dev cluster

## Release Workflow:
1. Developer creates a release/v1.2.3 branch
2. CI builds the image and pushes it to GHCR with the `staging-latest` tag
3. CI calls the shared workflow to update `environments/staging/go-http-server/kustomization.yaml`
4. ArgoCD auto-syncs to the staging cluster
5. QA performs testing in the staging environment
6. Developer creates a v1.2.3 tag
7. CI builds the image with the v1.2.3 tag
8. CI updates `environments/prod/go-http-server/kustomization.yaml` with the v1.2.3 tag (requires manual approval)
9. Platform Engineer approves the deployment in the ArgoCD UI
10. ArgoCD syncs to the production cluster