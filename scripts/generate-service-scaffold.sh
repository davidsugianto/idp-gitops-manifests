#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if service name is provided
if [ -z "$1" ] || [ -z "$2" ]; then
    echo -e "${RED}Error: Service name and registry are required${NC}"
    echo "Usage: $0 <service-name> <registry>"
    echo "Example: $0 go-payment-service ghcr.io/my-org"
    exit 1
fi

SERVICE_NAME=$1
REGISTRY=$2
IMAGE_NAME="${REGISTRY}/${SERVICE_NAME}"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🚀 Generating scaffold for service: ${SERVICE_NAME}${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Create base directory
BASE_DIR="bases/${SERVICE_NAME}"
mkdir -p "${BASE_DIR}"

echo -e "${YELLOW}📦 Creating base manifests...${NC}"

# Create deployment.yaml (without hardcoded image tag)
cat > "${BASE_DIR}/deployment.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SERVICE_NAME}
  labels:
    app: ${SERVICE_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${SERVICE_NAME}
  template:
    metadata:
      labels:
        app: ${SERVICE_NAME}
    spec:
      containers:
      - name: ${SERVICE_NAME}
        image: ${IMAGE_NAME}:latest  # Placeholder, will be overridden by kustomize images field
        ports:
        - containerPort: 8080
          name: http
        env:
        - name: PORT
          value: "8080"
        - name: ENV
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        livenessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
EOF

# Create service.yaml
cat > "${BASE_DIR}/service.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${SERVICE_NAME}
  labels:
    app: ${SERVICE_NAME}
spec:
  type: ClusterIP
  selector:
    app: ${SERVICE_NAME}
  ports:
  - port: 80
    targetPort: 8080
    protocol: TCP
    name: http
EOF

# Create ingress.yaml
cat > "${BASE_DIR}/ingress.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${SERVICE_NAME}
  labels:
    app: ${SERVICE_NAME}
spec:
  ingressClassName: nginx
  rules:
  - host: ${SERVICE_NAME}.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${SERVICE_NAME}
            port:
              number: 80
EOF

# Create hpa.yaml
cat > "${BASE_DIR}/hpa.yaml" <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${SERVICE_NAME}
  labels:
    app: ${SERVICE_NAME}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${SERVICE_NAME}
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 70
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 80
EOF

# Create external-secret.yaml
cat > "${BASE_DIR}/external-secret.yaml" <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ${SERVICE_NAME}-secrets
  labels:
    app: ${SERVICE_NAME}
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secret-store
    kind: ClusterSecretStore
  target:
    name: ${SERVICE_NAME}-secrets
    creationPolicy: Owner
  data:
  - secretKey: database-url
    remoteRef:
      key: /dev/${SERVICE_NAME}/database
      property: url
EOF

# Create kustomization.yaml (without field images:)
cat > "${BASE_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - hpa.yaml
  - external-secret.yaml

components:
  - ../../components/security-hardening
  - ../../components/observability
  - ../../components/common-labels
EOF

echo -e "${GREEN}✅ Base manifests created in ${BASE_DIR}${NC}"
echo ""

# Create environment overlays
for ENV in dev staging prod; do
    ENV_DIR="environments/${ENV}/${SERVICE_NAME}"
    PATCHES_DIR="${ENV_DIR}/patches"
    mkdir -p "${PATCHES_DIR}"
    
    echo -e "${YELLOW}🎨 Creating ${ENV} environment overlay...${NC}"
    
    # Determine image tag per environment
    if [ "$ENV" == "dev" ]; then
        IMAGE_TAG="dev-latest"
    elif [ "$ENV" == "staging" ]; then
        IMAGE_TAG="staging-latest"
    else
        IMAGE_TAG="latest"  # Prod will be updated by manual or via release workflow
    fi
    
    if [ "$ENV" == "prod" ]; then
        # ═══════════════════════════════════════════════════════════════
        # PRODUCTION: Dedicated namespace with isolation resources
        # ═══════════════════════════════════════════════════════════════
        
        # Create namespace.yaml
        cat > "${ENV_DIR}/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: prod-${SERVICE_NAME}
  labels:
    environment: prod
    service: ${SERVICE_NAME}
    tier: backend
EOF

        # Create resource-quota.yaml
        cat > "${ENV_DIR}/resource-quota.yaml" <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${SERVICE_NAME}-quota
  namespace: prod-${SERVICE_NAME}
spec:
  hard:
    requests.cpu: "4"
    requests.memory: 8Gi
    limits.cpu: "8"
    limits.memory: 16Gi
    pods: "20"
    services: "5"
    configmaps: "10"
    secrets: "10"
EOF

        # Create limit-range.yaml
        cat > "${ENV_DIR}/limit-range.yaml" <<EOF
apiVersion: v1
kind: LimitRange
metadata:
  name: ${SERVICE_NAME}-limits
  namespace: prod-${SERVICE_NAME}
spec:
  limits:
  - default:
      cpu: 500m
      memory: 512Mi
    defaultRequest:
      cpu: 200m
      memory: 256Mi
    max:
      cpu: "2"
      memory: 2Gi
    min:
      cpu: 100m
      memory: 128Mi
    type: Container
EOF

        # Create network-policy.yaml
        cat > "${ENV_DIR}/network-policy.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${SERVICE_NAME}-netpol
  namespace: prod-${SERVICE_NAME}
spec:
  podSelector:
    matchLabels:
      app: ${SERVICE_NAME}
  policyTypes:
  - Ingress
  - Egress
  
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ingress-nginx
  - from:
    - namespaceSelector:
        matchLabels:
          environment: prod
  
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  - to:
    - namespaceSelector:
        matchLabels:
          environment: prod
EOF

        # Create pod-disruption-budget.yaml
        cat > "${ENV_DIR}/pod-disruption-budget.yaml" <<EOF
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: ${SERVICE_NAME}-pdb
  namespace: prod-${SERVICE_NAME}
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: ${SERVICE_NAME}
EOF

        # Create kustomization.yaml for prod (DENGAN field images:)
        cat > "${ENV_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
  - resource-quota.yaml
  - limit-range.yaml
  - network-policy.yaml
  - pod-disruption-budget.yaml
  - ../../../bases/${SERVICE_NAME}

# Image tag for production (manual update or via release workflow)
images:
  - name: ${IMAGE_NAME}
    newTag: ${IMAGE_TAG}

patches:
  - path: patches/deployment-patch.yaml
  - path: patches/ingress-patch.yaml
  - path: patches/hpa-patch.yaml
  - path: patches/resource-patch.yaml
EOF

        echo -e "${GREEN}  ✅ Production: Dedicated namespace (prod-${SERVICE_NAME})${NC}"
        echo -e "${GREEN}  ✅ Image tag: ${IMAGE_TAG}${NC}"
        
    else
        # ═══════════════════════════════════════════════════════════════
        # DEV/STAGING: Shared namespace (simpler)
        # ═══════════════════════════════════════════════════════════════
        
        # Create kustomization.yaml for dev/staging (DENGAN field images:)
        cat > "${ENV_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${ENV}

resources:
  - ../../../bases/${SERVICE_NAME}

# Image tag untuk ${ENV} (akan di-update otomatis oleh CI workflow)
images:
  - name: ${IMAGE_NAME}
    newTag: ${IMAGE_TAG}

patches:
  - path: patches/deployment-patch.yaml
  - path: patches/ingress-patch.yaml
  - path: patches/hpa-patch.yaml
  - path: patches/resource-patch.yaml
EOF

        echo -e "${GREEN}  ✅ ${ENV}: Shared namespace (${ENV})${NC}"
        echo -e "${GREEN}  ✅ Image tag: ${IMAGE_TAG}${NC}"
    fi
    
    # ═══════════════════════════════════════════════════════════════
    # COMMON: Patches for all environment (without image override)
    # ═══════════════════════════════════════════════════════════════
    
    # Create deployment-patch.yaml (without image override)
    if [ "$ENV" == "dev" ]; then
        LOG_LEVEL="debug"
    elif [ "$ENV" == "staging" ]; then
        LOG_LEVEL="info"
    else
        LOG_LEVEL="warn"
    fi
    
    cat > "${PATCHES_DIR}/deployment-patch.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SERVICE_NAME}
spec:
  replicas: 1
  template:
    spec:
      containers:
      - name: ${SERVICE_NAME}
        env:
        - name: LOG_LEVEL
          value: "${LOG_LEVEL}"
EOF

    # Create ingress-patch.yaml
    if [ "$ENV" == "prod" ]; then
        HOST="${SERVICE_NAME}.davidsugianto.com"
    else
        HOST="${ENV}.${SERVICE_NAME}.davidsugianto.com"
    fi
    
    cat > "${PATCHES_DIR}/ingress-patch.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${SERVICE_NAME}
spec:
  rules:
  - host: ${HOST}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${SERVICE_NAME}
            port:
              number: 80
EOF

    # Create hpa-patch.yaml
    if [ "$ENV" == "dev" ]; then
        MIN_REPLICAS=1
        MAX_REPLICAS=3
    elif [ "$ENV" == "staging" ]; then
        MIN_REPLICAS=2
        MAX_REPLICAS=5
    else
        MIN_REPLICAS=3
        MAX_REPLICAS=10
    fi
    
    cat > "${PATCHES_DIR}/hpa-patch.yaml" <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${SERVICE_NAME}
spec:
  minReplicas: ${MIN_REPLICAS}
  maxReplicas: ${MAX_REPLICAS}
EOF

    # Create resource-patch.yaml
    if [ "$ENV" == "dev" ]; then
        CPU_REQ="50m"
        MEM_REQ="64Mi"
        CPU_LIM="200m"
        MEM_LIM="256Mi"
    elif [ "$ENV" == "staging" ]; then
        CPU_REQ="100m"
        MEM_REQ="128Mi"
        CPU_LIM="500m"
        MEM_LIM="512Mi"
    else
        CPU_REQ="200m"
        MEM_REQ="256Mi"
        CPU_LIM="1000m"
        MEM_LIM="1Gi"
    fi
    
    cat > "${PATCHES_DIR}/resource-patch.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${SERVICE_NAME}
spec:
  template:
    spec:
      containers:
      - name: ${SERVICE_NAME}
        resources:
          requests:
            cpu: "${CPU_REQ}"
            memory: "${MEM_REQ}"
          limits:
            cpu: "${CPU_LIM}"
            memory: "${MEM_LIM}"
EOF
    
    echo -e "${GREEN}  ✅ Patches created for ${ENV}${NC}"
done

echo ""
echo -e "${YELLOW}🔧 Updating environment kustomization files...${NC}"

# Add service to dev/staging environment kustomization.yaml
for ENV in dev staging; do
    KUSTOMIZATION_FILE="environments/${ENV}/kustomization.yaml"
    
    if [ -f "$KUSTOMIZATION_FILE" ]; then
        if ! grep -q "- ${SERVICE_NAME}" "$KUSTOMIZATION_FILE"; then
            echo "  - ${SERVICE_NAME}" >> "$KUSTOMIZATION_FILE"
            echo -e "${GREEN}  ✅ Added ${SERVICE_NAME} to environments/${ENV}/kustomization.yaml${NC}"
        else
            echo -e "${BLUE}  ℹ️  ${SERVICE_NAME} already in environments/${ENV}/kustomization.yaml${NC}"
        fi
    fi
done

# Add service to prod environment kustomization.yaml
KUSTOMIZATION_FILE="environments/prod/kustomization.yaml"
if [ -f "$KUSTOMIZATION_FILE" ]; then
    if ! grep -q "- ${SERVICE_NAME}" "$KUSTOMIZATION_FILE"; then
        echo "  - ${SERVICE_NAME}" >> "$KUSTOMIZATION_FILE"
        echo -e "${GREEN}  ✅ Added ${SERVICE_NAME} to environments/prod/kustomization.yaml${NC}"
    else
        echo -e "${BLUE}  ℹ️  ${SERVICE_NAME} already in environments/prod/kustomization.yaml${NC}"
    fi
fi

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🎉 Scaffold generation complete!${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}📋 Summary:${NC}"
echo "  Service: ${SERVICE_NAME}"
echo "  Image: ${IMAGE_NAME}"
echo ""
echo -e "${YELLOW}🏷️  Image Tags per Environment:${NC}"
echo "  Dev:     ${IMAGE_NAME}:dev-latest (auto-update via CI)"
echo "  Staging: ${IMAGE_NAME}:staging-latest (auto-update via CI)"
echo "  Prod:    ${IMAGE_NAME}:latest (manual or release workflow)"
echo ""
echo -e "${YELLOW}📁 Files created:${NC}"
echo "  ✅ bases/${SERVICE_NAME}/"
echo "  ✅ environments/dev/${SERVICE_NAME}/ (shared namespace: dev)"
echo "  ✅ environments/staging/${SERVICE_NAME}/ (shared namespace: staging)"
echo "  ✅ environments/prod/${SERVICE_NAME}/ (dedicated namespace: prod-${SERVICE_NAME})"
echo ""
echo -e "${YELLOW}🚀 Next steps:${NC}"
echo "  1. Review and customize the generated manifests"
echo "  2. Setup CI workflow in application repo to call shared workflow"
echo "  3. Commit and create a Pull Request:"
echo ""
echo -e "${BLUE}     git add .${NC}"
echo -e "${BLUE}     git commit -m \"feat: add ${SERVICE_NAME}\"${NC}"
echo -e "${BLUE}     git push origin main${NC}"
echo ""
echo -e "${YELLOW}⚠️  Important:${NC}"
echo "  - Dev/Staging image tags will be auto-updated by CI workflow"
echo "  - Production requires manual approval in ArgoCD"
echo "  - Production has dedicated namespace with strict isolation"
echo ""