# Kustomize Guide

## Directory Structure

```text
.
├── bases/
│   └── my-new-service/
│       ├── deployment.yaml
│       ├── service.yaml
│       └── kustomization.yaml
└── environments/
    └── dev/
        └── my-new-service/
            ├── kustomization.yaml
            └── patches/
                └── deployment-patch.yaml
```

## Common Operations

### Override Image Tag

In `environments/dev/my-new-service/patches/deployment-patch.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-new-service
spec:
  template:
    spec:
      containers:
      - name: my-new-service
        image: ghcr.io/my-org/my-new-service:v1.2.3
```

### Add Environment Variable

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-new-service
spec:
  template:
    spec:
      containers:
      - name: my-new-service
        env:
        - name: MY_VAR
          value: "my-value"
```

### Scale Replicas

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-new-service
spec:
  replicas: 5
```

### Components

Components are reusable configurations that can be applied to multiple services:

```yaml
# In base kustomization.yaml
components:
  - ../../components/security-hardening
  - ../../components/observability
```

### Testing Locally

```bash
# Build and view final manifests
kustomize build environments/dev/my-new-service

# Validate schema
kustomize build environments/dev/my-new-service | kubeconform -strict
```

