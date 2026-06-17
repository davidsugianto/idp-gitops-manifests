#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}🔍 Validating all Kubernetes manifests...${NC}"
echo ""

ERRORS=0

# Find all kustomization.yaml files
for KUSTOMIZATION in $(find environments/ -name "kustomization.yaml"); do
    ENV_DIR=$(dirname "$KUSTOMIZATION")
    echo -e "${YELLOW}Validating: ${ENV_DIR}${NC}"
    
    # Try to build with kustomize
    if ! kustomize build "$ENV_DIR" > /dev/null 2>&1; then
        echo -e "${RED}❌ Kustomize build failed for ${ENV_DIR}${NC}"
        kustomize build "$ENV_DIR"
        ERRORS=$((ERRORS + 1))
    else
        echo -e "${GREEN}✅ Kustomize build successful${NC}"
    fi
    
    # Validate with kubeconform
    if ! kustomize build "$ENV_DIR" | kubeconform -strict -kubernetes-version 1.28.0 2>&1; then
        echo -e "${RED}❌ Schema validation failed for ${ENV_DIR}${NC}"
        ERRORS=$((ERRORS + 1))
    else
        echo -e "${GREEN}✅ Schema validation passed${NC}"
    fi
    
    echo ""
done

if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}🎉 All validations passed!${NC}"
    exit 0
else
    echo -e "${RED}❌ ${ERRORS} validation(s) failed${NC}"
    exit 1
fi