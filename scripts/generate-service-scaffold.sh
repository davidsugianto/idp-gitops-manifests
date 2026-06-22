#!/bin/bash

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SERVICE_NAME=""
REGISTRY=""
IMAGE_NAME=""
ENVIRONMENTS="dev,staging,prod"
INCLUDE_INGRESS=true
INCLUDE_HPA=true
INCLUDE_EXTERNAL_SECRET=true
SECRET_STORE_TYPE="aws"
SECRET_KEYS="database-url,api-key"
PORT="8080"
HEALTH_PATH="/health"
READINESS_PATH="/ready"

print_usage() {
    cat <<'EOF'
Usage:
  ./scripts/generate-service-scaffold.sh <service-name> <registry> [secret-store] [secret-keys] [skip-external-secret]
  ./scripts/generate-service-scaffold.sh [options]

Options:
  --service-name <name>
  --registry <registry>
  --image-name <image>
  --environments <dev,staging,prod>
  --include-ingress <true|false>
  --include-hpa <true|false>
  --include-external-secret <true|false>
  --secret-store-type <aws|vault|gcp>
  --secret-keys <comma,separated,keys>
  --port <port>
  --health-check-path <path>
  --readiness-check-path <path>
  --skip-secrets
  --help
EOF
}

trim() {
    printf '%s' "$1" | xargs
}

bool_string() {
    case "$1" in
        true|false) ;;
        *)
            echo -e "${RED}Error: expected true or false, got '$1'${NC}" >&2
            exit 1
            ;;
    esac
}

store_name_for_type() {
    case "$1" in
        aws) printf 'aws-secret-store' ;;
        vault) printf 'vault-secret-store' ;;
        gcp) printf 'gcp-secret-store' ;;
    esac
}

parse_args() {
    if [ $# -eq 0 ]; then
        print_usage
        exit 1
    fi

    if [ "$1" = "--help" ]; then
        print_usage
        exit 0
    fi

    if [[ "$1" != --* ]]; then
        if [ $# -lt 2 ]; then
            echo -e "${RED}Error: service name and registry are required${NC}" >&2
            print_usage
            exit 1
        fi

        SERVICE_NAME=$1
        REGISTRY=$2
        shift 2

        if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
            SECRET_STORE_TYPE=$1
            shift
        fi
        if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
            SECRET_KEYS=$1
            shift
        fi
        if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
            if [ "$1" = "true" ]; then
                INCLUDE_EXTERNAL_SECRET=false
            elif [ "$1" = "false" ]; then
                INCLUDE_EXTERNAL_SECRET=true
            else
                echo -e "${RED}Error: legacy skip-external-secret must be true or false${NC}" >&2
                exit 1
            fi
            shift
        fi
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --service-name)
                SERVICE_NAME=$2
                shift 2
                ;;
            --registry)
                REGISTRY=$2
                shift 2
                ;;
            --image-name)
                IMAGE_NAME=$2
                shift 2
                ;;
            --environments)
                ENVIRONMENTS=$2
                shift 2
                ;;
            --include-ingress)
                bool_string "$2"
                INCLUDE_INGRESS=$2
                shift 2
                ;;
            --include-hpa)
                bool_string "$2"
                INCLUDE_HPA=$2
                shift 2
                ;;
            --include-external-secret)
                bool_string "$2"
                INCLUDE_EXTERNAL_SECRET=$2
                shift 2
                ;;
            --secret-store-type|--secret-store)
                SECRET_STORE_TYPE=$2
                shift 2
                ;;
            --secret-keys)
                SECRET_KEYS=$2
                shift 2
                ;;
            --port)
                PORT=$2
                shift 2
                ;;
            --health-check-path)
                HEALTH_PATH=$2
                shift 2
                ;;
            --readiness-check-path)
                READINESS_PATH=$2
                shift 2
                ;;
            --skip-secrets)
                INCLUDE_EXTERNAL_SECRET=false
                shift
                ;;
            --help)
                print_usage
                exit 0
                ;;
            *)
                echo -e "${RED}Error: unknown argument '$1'${NC}" >&2
                print_usage
                exit 1
                ;;
        esac
    done

    if [ -z "$IMAGE_NAME" ]; then
        if [ -z "$REGISTRY" ] || [ -z "$SERVICE_NAME" ]; then
            echo -e "${RED}Error: provide --image-name or both service name and registry${NC}" >&2
            exit 1
        fi
        IMAGE_NAME="${REGISTRY}/${SERVICE_NAME}"
    fi
}

validate_inputs() {
    if [[ ! "$SERVICE_NAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        echo -e "${RED}Error: invalid service name '${SERVICE_NAME}'${NC}" >&2
        exit 1
    fi

    if [ ${#SERVICE_NAME} -gt 63 ]; then
        echo -e "${RED}Error: service name too long (max 63 characters)${NC}" >&2
        exit 1
    fi

    if [[ ! "$PORT" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}Error: port must be numeric${NC}" >&2
        exit 1
    fi

    case "$SECRET_STORE_TYPE" in
        aws|vault|gcp) ;;
        *)
            echo -e "${RED}Error: secret store type must be aws, vault, or gcp${NC}" >&2
            exit 1
            ;;
    esac

    bool_string "$INCLUDE_INGRESS"
    bool_string "$INCLUDE_HPA"
    bool_string "$INCLUDE_EXTERNAL_SECRET"

    IFS=',' read -ra ENV_ARRAY <<< "$ENVIRONMENTS"
    if [ ${#ENV_ARRAY[@]} -eq 0 ]; then
        echo -e "${RED}Error: at least one environment is required${NC}" >&2
        exit 1
    fi

    VALIDATED_ENVIRONMENTS=()
    for raw_env in "${ENV_ARRAY[@]}"; do
        env=$(trim "$raw_env")
        case "$env" in
            dev|staging|prod)
                VALIDATED_ENVIRONMENTS+=("$env")
                ;;
            *)
                echo -e "${RED}Error: unsupported environment '${env}'${NC}" >&2
                exit 1
                ;;
        esac
    done
}

build_secret_data() {
    local data=""
    IFS=',' read -ra KEYS_ARRAY <<< "$SECRET_KEYS"
    for raw_key in "${KEYS_ARRAY[@]}"; do
        local key
        key=$(trim "$raw_key")
        [ -n "$key" ] || continue
        case "$SECRET_STORE_TYPE" in
            aws|vault)
                data="${data}
  - secretKey: ${key}
    remoteRef:
      key: ${SECRET_PATH_PREFIX}
      property: ${key}"
                ;;
            gcp)
                data="${data}
  - secretKey: ${key}
    remoteRef:
      key: ${SECRET_PATH_PREFIX}/${key}
      version: latest"
                ;;
        esac
    done
    printf '%s' "$data"
}

base_resources_block() {
    local resources=("deployment.yaml" "service.yaml")
    if [ "$INCLUDE_INGRESS" = true ]; then
        resources+=("ingress.yaml")
    fi
    if [ "$INCLUDE_HPA" = true ]; then
        resources+=("hpa.yaml")
    fi
    if [ "$INCLUDE_EXTERNAL_SECRET" = true ]; then
        resources+=("external-secret.yaml")
    fi

    for resource in "${resources[@]}"; do
        printf '  - %s\n' "$resource"
    done
}

patches_block() {
    printf '  - path: patches/deployment-patch.yaml\n'
    printf '  - path: patches/resource-patch.yaml\n'
    if [ "$INCLUDE_INGRESS" = true ]; then
        printf '  - path: patches/ingress-patch.yaml\n'
    fi
    if [ "$INCLUDE_HPA" = true ]; then
        printf '  - path: patches/hpa-patch.yaml\n'
    fi
}

generate_base_manifests() {
    BASE_DIR="bases/${SERVICE_NAME}"
    mkdir -p "$BASE_DIR"

    echo -e "${YELLOW}📦 Creating base manifests...${NC}"

    cat > "$BASE_DIR/deployment.yaml" <<EOF
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
        image: ${IMAGE_NAME}:latest
        ports:
        - containerPort: ${PORT}
          name: http
        env:
        - name: PORT
          value: "${PORT}"
        - name: ENV
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
EOF

    if [ "$INCLUDE_EXTERNAL_SECRET" = true ]; then
        cat >> "$BASE_DIR/deployment.yaml" <<EOF
        envFrom:
        - secretRef:
            name: ${SERVICE_NAME}-secrets
EOF
    fi

    cat >> "$BASE_DIR/deployment.yaml" <<EOF
        livenessProbe:
          httpGet:
            path: ${HEALTH_PATH}
            port: ${PORT}
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: ${READINESS_PATH}
            port: ${PORT}
          initialDelaySeconds: 5
          periodSeconds: 5
EOF

    cat > "$BASE_DIR/service.yaml" <<EOF
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
    targetPort: ${PORT}
    protocol: TCP
    name: http
EOF

    if [ "$INCLUDE_INGRESS" = true ]; then
        cat > "$BASE_DIR/ingress.yaml" <<EOF
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
    fi

    if [ "$INCLUDE_HPA" = true ]; then
        cat > "$BASE_DIR/hpa.yaml" <<EOF
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
    fi

    if [ "$INCLUDE_EXTERNAL_SECRET" = true ]; then
        echo -e "${YELLOW}🔐 Creating external secret configuration...${NC}"
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
        esac

        SECRET_DATA=$(build_secret_data)
        cat > "$BASE_DIR/external-secret.yaml" <<EOF
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
    else
        echo -e "${BLUE}  ℹ️  Skipping external secret generation${NC}"
    fi

    RESOURCES=$(base_resources_block)
    cat > "$BASE_DIR/kustomization.yaml" <<EOF
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
}

env_image_tag() {
    case "$1" in
        dev) printf 'dev-latest' ;;
        staging) printf 'staging-latest' ;;
        prod) printf 'latest' ;;
    esac
}

set_env_defaults() {
    case "$1" in
        dev)
            LOG_LEVEL="debug"
            CPU_REQ="50m"
            MEM_REQ="64Mi"
            CPU_LIM="200m"
            MEM_LIM="256Mi"
            MIN_REPLICAS=1
            MAX_REPLICAS=3
            ;;
        staging)
            LOG_LEVEL="info"
            CPU_REQ="100m"
            MEM_REQ="128Mi"
            CPU_LIM="500m"
            MEM_LIM="512Mi"
            MIN_REPLICAS=2
            MAX_REPLICAS=5
            ;;
        prod)
            LOG_LEVEL="warn"
            CPU_REQ="200m"
            MEM_REQ="256Mi"
            CPU_LIM="1000m"
            MEM_LIM="1Gi"
            MIN_REPLICAS=3
            MAX_REPLICAS=10
            ;;
    esac
}

generate_env_overlay() {
    local env="$1"
    local env_dir="environments/${env}/${SERVICE_NAME}"
    local patches_dir="${env_dir}/patches"
    local image_tag
    local patches

    mkdir -p "$patches_dir"
    image_tag=$(env_image_tag "$env")
    patches=$(patches_block)

    echo -e "${YELLOW}🎨 Creating ${env} environment overlay...${NC}"

    if [ "$env" = "prod" ]; then
        cat > "$env_dir/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: prod-${SERVICE_NAME}
  labels:
    environment: prod
    service: ${SERVICE_NAME}
    tier: backend
EOF

        cat > "$env_dir/resource-quota.yaml" <<EOF
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

        cat > "$env_dir/limit-range.yaml" <<EOF
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

        cat > "$env_dir/network-policy.yaml" <<EOF
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

        cat > "$env_dir/pod-disruption-budget.yaml" <<EOF
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

        cat > "$env_dir/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
  - resource-quota.yaml
  - limit-range.yaml
  - network-policy.yaml
  - pod-disruption-budget.yaml
  - ../../../bases/${SERVICE_NAME}

images:
  - name: ${IMAGE_NAME}
    newTag: ${image_tag}

patches:
${patches}
EOF

        echo -e "${GREEN}  ✅ Production: Dedicated namespace (prod-${SERVICE_NAME})${NC}"
    else
        cat > "$env_dir/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: ${env}

resources:
  - ../../../bases/${SERVICE_NAME}

images:
  - name: ${IMAGE_NAME}
    newTag: ${image_tag}

patches:
${patches}
EOF

        echo -e "${GREEN}  ✅ ${env}: Shared namespace (${env})${NC}"
    fi

    set_env_defaults "$env"

    cat > "$patches_dir/deployment-patch.yaml" <<EOF
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

    cat > "$patches_dir/resource-patch.yaml" <<EOF
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

    if [ "$INCLUDE_INGRESS" = true ]; then
        if [ "$env" = "prod" ]; then
            HOST="${SERVICE_NAME}.davidsugianto.com"
        else
            HOST="${env}.${SERVICE_NAME}.davidsugianto.com"
        fi

        cat > "$patches_dir/ingress-patch.yaml" <<EOF
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
    fi

    if [ "$INCLUDE_HPA" = true ]; then
        cat > "$patches_dir/hpa-patch.yaml" <<EOF
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${SERVICE_NAME}
spec:
  minReplicas: ${MIN_REPLICAS}
  maxReplicas: ${MAX_REPLICAS}
EOF
    fi

    echo -e "${GREEN}  ✅ Image tag: ${image_tag}${NC}"
    echo -e "${GREEN}  ✅ Patches created for ${env}${NC}"
}

update_top_level_kustomization() {
    local env="$1"
    local file="environments/${env}/kustomization.yaml"
    local entry="  - ${SERVICE_NAME}"

    [ -f "$file" ] || return 0

    if grep -Fq -- "$entry" "$file"; then
        echo -e "${BLUE}  ℹ️  ${SERVICE_NAME} already in ${file}${NC}"
        return 0
    fi

    printf '%s\n' "$entry" >> "$file"
    echo -e "${GREEN}  ✅ Added ${SERVICE_NAME} to ${file}${NC}"
}

print_summary() {
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}🎉 Scaffold generation complete!${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}📋 Summary:${NC}"
    echo "  Service: ${SERVICE_NAME}"
    echo "  Image: ${IMAGE_NAME}"
    echo "  Environments: ${ENVIRONMENTS}"
    echo "  Port: ${PORT}"
    echo "  Health Check: ${HEALTH_PATH}"
    echo "  Readiness Check: ${READINESS_PATH}"
    if [ "$INCLUDE_EXTERNAL_SECRET" = true ]; then
        echo "  Secret Store: ${SECRET_STORE_TYPE}"
        echo "  Secret Keys: ${SECRET_KEYS}"
    else
        echo "  External Secret: skipped"
    fi
    echo ""
    echo -e "${YELLOW}📁 Files created:${NC}"
    echo "  ✅ bases/${SERVICE_NAME}/"
    for env in "${VALIDATED_ENVIRONMENTS[@]}"; do
        if [ "$env" = "prod" ]; then
            echo "  ✅ environments/prod/${SERVICE_NAME}/ (dedicated namespace: prod-${SERVICE_NAME})"
        else
            echo "  ✅ environments/${env}/${SERVICE_NAME}/ (shared namespace: ${env})"
        fi
    done

    if [ "$INCLUDE_EXTERNAL_SECRET" = true ]; then
        echo ""
        echo -e "${YELLOW}🔐 External Secrets Configuration:${NC}"
        echo "  Store Type: ${SECRET_STORE_TYPE}"
        echo "  Store Name: $(store_name_for_type "$SECRET_STORE_TYPE")"
        IFS=',' read -ra KEYS_ARRAY <<< "$SECRET_KEYS"
        for raw_key in "${KEYS_ARRAY[@]}"; do
            key=$(trim "$raw_key")
            [ -n "$key" ] || continue
            echo "  Secret Key: ${key}"
        done
    fi
}

main() {
    parse_args "$@"
    validate_inputs

    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}🚀 Generating scaffold for service: ${SERVICE_NAME}${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${YELLOW}📋 Configuration:${NC}"
    echo "  Service Name: ${SERVICE_NAME}"
    echo "  Image: ${IMAGE_NAME}"
    echo "  Environments: ${ENVIRONMENTS}"
    echo "  Include Ingress: ${INCLUDE_INGRESS}"
    echo "  Include HPA: ${INCLUDE_HPA}"
    echo "  Include External Secret: ${INCLUDE_EXTERNAL_SECRET}"
    echo "  Port: ${PORT}"
    echo "  Health Check: ${HEALTH_PATH}"
    echo "  Readiness Check: ${READINESS_PATH}"
    if [ "$INCLUDE_EXTERNAL_SECRET" = true ]; then
        echo "  Secret Store Type: ${SECRET_STORE_TYPE}"
        echo "  Secret Keys: ${SECRET_KEYS}"
    fi
    echo ""

    generate_base_manifests

    for env in "${VALIDATED_ENVIRONMENTS[@]}"; do
        generate_env_overlay "$env"
    done

    echo ""
    echo -e "${YELLOW}🔧 Updating environment kustomization files...${NC}"
    for env in "${VALIDATED_ENVIRONMENTS[@]}"; do
        update_top_level_kustomization "$env"
    done

    print_summary
}

main "$@"
