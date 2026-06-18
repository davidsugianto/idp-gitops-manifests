#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ═══════════════════════════════════════════════════════════════
# USAGE & ARGUMENTS
# ═══════════════════════════════════════════════════════════════

# Check if service name is provided
if [ -z "$1" ] || [ -z "$2" ]; then
    echo -e "${RED}Error: Service name and registry are required${NC}"
    echo "Usage: $0 <service-name> <registry> [options]"
    echo ""
    echo "Required:"
    echo "  \$1  Service name (e.g., go-payment-service)"
    echo "  \$2  Registry URL (e.g., ghcr.io/my-org)"
    echo ""
    echo "Optional:"
    echo "  \$3  Secret store type: aws|vault|gcp (default: aws)"
    echo "  \$4  Comma-separated secret keys (default: database-url,api-key)"
    echo "  \$5  Skip external secret: true|false (default: false)"
    echo ""
    echo "Examples:"
    echo "  $0 go-payment-service ghcr.io/my-org"
    echo "  $0 go-payment-service ghcr.io/my-org vault db-password,redis-url"
    echo "  $0 go-payment-service ghcr.io/my-org aws database-url true"
    exit 1
fi

SERVICE_NAME=$1
REGISTRY=$2
SECRET_STORE_TYPE=${3:-aws}
SECRET_KEYS=${4:-"database-url,api-key"}
SKIP_EXTERNAL_SECRET=${5:-false}

IMAGE_NAME="${REGISTRY}/${SERVICE_NAME}"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🚀 Generating scaffold for service: ${SERVICE_NAME}${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}📋 Configuration:${NC}"
echo "  Service Name: ${SERVICE_NAME}"
echo "  Registry: ${REGISTRY}"
echo "  Image: ${IMAGE_NAME}"
echo "  Secret Store Type: ${SECRET_STORE_TYPE}"
echo "  Secret Keys: ${SECRET_KEYS}"
echo "  Skip External Secret: ${SKIP_EXTERNAL_SECRET}"
echo ""

# Create base directory
BASE_DIR="bases/${SERVICE_NAME}"
mkdir -p "${BASE_DIR}"

echo -e "${YELLOW}📦 Creating base manifests...${NC}"

# ═══════════════════════════════════════════════════════════════
# CREATE DEPLOYMENT.YAML
# ═══════════════════════════════════════════════════════════════
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
EOF

# Add envFrom if external secret is enabled
if [ "$SKIP_EXTERNAL_SECRET" != "true" ]; then
    cat >> "${BASE_DIR}/deployment.yaml" <<EOF
        envFrom:
        - secretRef:
            name: ${SERVICE_NAME}-secrets
EOF
fi

# Add probes
cat >> "${BASE_DIR}/deployment.yaml" <<EOF
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

# ═══════════════════════════════════════════════════════════════
# CREATE SERVICE.YAML
# ═══════════════════════════════════════════════════════════════
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

# ═══════════════════════════════════════════════════════════════
# CREATE INGRESS.YAML
# ═══════════════════════════════════════════════════════════════
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

# ═══════════════════════════════════════════════════════════════
# CREATE HPA.YAML
# ═══════════════════════════════════════════════════════════════
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

# ═══════════════════════════════════════════════════════════════
# CREATE EXTERNAL-SECRET.YAML (CONFIGURABLE)
# ═══════════════════════════════════════════════════════════════
if [ "$SKIP_EXTERNAL_SECRET" != "true" ]; then
    echo -e "${YELLOW}🔐 Creating external secret configuration...${NC}"
    
    # Determine secret store configuration based on type
    case "$SECRET_STORE_TYPE" in
        aws)
            STORE_NAME="aws-secret-store"
            STORE_KIND="ClusterSecretStore"
            SECRET_PATH_PREFIX="/dev/${SERVICE_NAME}"
            ;;
        vault)
            STORE_NAME="vault-secret-store"
            STORE_KIND="ClusterSecretStore"
            SECRET_PATH_PREFIX="secret/data/dev/${SERVICE_NAME}"
            ;;
        gcp)
            STORE_NAME="gcp-secret-store"
            STORE_KIND="ClusterSecretStore"
            SECRET_PATH_PREFIX="projects/my-project/secrets"
            ;;
        *)
            echo -e "${RED}❌ Unknown secret store type: ${SECRET_STORE_TYPE}${NC}"
            echo "Supported types: aws, vault, gcp"
            exit 1
            ;;
    esac
    
    # Build the data section based on secret keys
    SECRET_DATA=""
    IFS=',' read -ra KEYS_ARRAY <<< "$SECRET_KEYS"
    for KEY in "${KEYS_ARRAY[@]}"; do
        KEY=$(echo "$KEY" | xargs)  # trim whitespace
        
        case "$SECRET_STORE_TYPE" in
            aws|vault)
                SECRET_DATA="${SECRET_DATA}
  - secretKey: ${KEY}
    remoteRef:
      key: ${SECRET_PATH_PREFIX}
      property: ${KEY}"
                ;;
            gcp)
                SECRET_DATA="${SECRET_DATA}
  - secretKey: ${KEY}
    remoteRef:
      key: ${SECRET_PATH_PREFIX}/${KEY}
      version: latest"
                ;;
        esac
    done
    
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
    name: ${STORE_NAME}
    kind: ${STORE_KIND}
  target:
    name: ${SERVICE_NAME}-secrets
    creationPolicy: Owner
  data:${SECRET_DATA}
EOF
    
    echo -e "${GREEN}  ✅ External secret created with store type: ${SECRET_STORE_TYPE}${NC}"
    echo -e "${GREEN}  ✅ Secret keys: ${SECRET_KEYS}${NC}"
else
    echo -e "${BLUE}  ℹ️  Skipping external secret generation${NC}"
fi

# ═══════════════════════════════════════════════════════════════
# CREATE KUSTOMIZATION.YAML (BASE)
# ═══════════════════════════════════════════════════════════════

# Build resources list
RESOURCES="  - deployment.yaml
  - service.yaml
  - ingress.yaml
  - hpa.yaml"

if [ "$SKIP_EXTERNAL_SECRET" != "true" ]; then
    RESOURCES="${RESOURCES}
  - external-secret.yaml"
fi

cat > "${BASE_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
${RESOURCES}

components:
  - ../../components/security-hardening
  - ../../components/observability
  - ../../components/common-labels
EOF

echo -e "${GREEN}✅ Base manifests created in ${BASE_DIR}${NC}"
echo ""

# ═══════════════════════════════════════════════════════════════
# CREATE ENVIRONMENT OVERLAYS
# ═══════════════════════════════════════════════════════════════

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
        IMAGE_TAG="latest"
    fi
    
    if [ "$ENV" == "prod" ]; then
        # ═══════════════════════════════════════════════════════════════
        # PRODUCTION: Dedicated namespace with isolation resources
        # ═══════════════════════════════════════════════════════════════
        
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
        
        cat > "${ENV_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${ENV}

resources:
  - ../../../bases/${SERVICE_NAME}

# Image tag for ${ENV} (will be auto-updated by CI workflow)
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
    # COMMON: Patches for all environment
    # ═══════════════════════════════════════════════════════════════
    
    # Determine environment-specific values
    if [ "$ENV" == "dev" ]; then
        LOG_LEVEL="debug"
        CPU_REQ="50m"
        MEM_REQ="64Mi"
        CPU_LIM="200m"
        MEM_LIM="256Mi"
        MIN_REPLICAS=1
        MAX_REPLICAS=3
    elif [ "$ENV" == "staging" ]; then
        LOG_LEVEL="info"
        CPU_REQ="100m"
        MEM_REQ="128Mi"
        CPU_LIM="500m"
        MEM_LIM="512Mi"
        MIN_REPLICAS=2
        MAX_REPLICAS=5
    else
        LOG_LEVEL="warn"
        CPU_REQ="200m"
        MEM_REQ="256Mi"
        CPU_LIM="1000m"
        MEM_LIM="1Gi"
        MIN_REPLICAS=3
        MAX_REPLICAS=10
    fi
    
    # Create deployment-patch.yaml
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
echo "  Secret Store: ${SECRET_STORE_TYPE}"
echo "  Secret Keys: ${SECRET_KEYS}"
echo ""
echo -e "${YELLOW}🏷️  Image Tags per Environment:${NC}"
echo "  Dev:     ${IMAGE_NAME}:dev-latest (auto-update via CI)"
echo "  Staging: ${IMAGE_NAME}:staging-latest (auto-update via CI)"
echo "  Prod:    ${IMAGE_NAME}:latest (manual or release workflow)"
echo ""
echo -e "${YELLOW}📁 Files created:${NC}"
echo "  ✅ bases/${SERVICE_NAME}/"
if [ "$SKIP_EXTERNAL_SECRET" != "true" ]; then
    echo "     └── external-secret.yaml (${SECRET_STORE_TYPE} store)"
fi
echo "  ✅ environments/dev/${SERVICE_NAME}/ (shared namespace: dev)"
echo "  ✅ environments/staging/${SERVICE_NAME}/ (shared namespace: staging)"
echo "  ✅ environments/prod/${SERVICE_NAME}/ (dedicated namespace: prod-${SERVICE_NAME})"
echo ""
echo -e "${YELLOW}🔐 External Secrets Configuration:${NC}"
if [ "$SKIP_EXTERNAL_SECRET" != "true" ]; then
    echo "  Store Type: ${SECRET_STORE_TYPE}"
    echo "  Store Name: $(case "$SECRET_STORE_TYPE" in aws) echo "aws-secret-store";; vault) echo "vault-secret-store";; gcp) echo "gcp-secret-store";; esac)"
    echo "  Secret Keys:"
    IFS=',' read -ra KEYS_ARRAY <<< "$SECRET_KEYS"
    for KEY in "${KEYS_ARRAY[@]}"; do
        KEY=$(echo "$KEY" | xargs)
        echo "    - ${KEY}"
    done
    echo ""
    echo -e "${YELLOW}⚠️  Important: Ensure the following secrets exist in your secret manager:${NC}"
    IFS=',' read -ra KEYS_ARRAY <<< "$SECRET_KEYS"
    for KEY in "${KEYS_ARRAY[@]}"; do
        KEY=$(echo "$KEY" | xargs)
        case "$SECRET_STORE_TYPE" in
            aws)
                echo "    AWS Secrets Manager: /dev/${SERVICE_NAME} → property: ${KEY}"
                ;;
            vault)
                echo "    Vault: secret/data/dev/${SERVICE_NAME} → field: ${KEY}"
                ;;
            gcp)
                echo "    GCP Secret Manager: projects/my-project/secrets/${KEY}"
                ;;
        esac
    done
else
    echo "  ⏭️  Skipped - no external secret will be created"
fi
echo ""
echo -e "${YELLOW}🚀 Next steps:${NC}"
echo "  1. Review and customize the generated manifests"
echo "  2. Ensure secrets exist in your secret manager (${SECRET_STORE_TYPE})"
echo "  3. Setup CI workflow in application repo to call shared workflow"
echo "  4. Commit and create a Pull Request:"
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