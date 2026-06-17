#!/bin/bash

# Check ArgoCD sync status for all applications

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}📊 ArgoCD Application Status${NC}"
echo ""

# Get all applications
APPS=$(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}')

SYNCED=0
OUT_OF_SYNC=0
DEGRADED=0

for APP in $APPS; do
    STATUS=$(kubectl get application "$APP" -n argocd -o jsonpath='{.status.sync.status}')
    HEALTH=$(kubectl get application "$APP" -n argocd -o jsonpath='{.status.health.status}')
    
    if [ "$STATUS" == "Synced" ] && [ "$HEALTH" == "Healthy" ]; then
        echo -e "${GREEN}✅ ${APP}: Synced & Healthy${NC}"
        SYNCED=$((SYNCED + 1))
    elif [ "$STATUS" == "OutOfSync" ]; then
        echo -e "${YELLOW}⚠️  ${APP}: Out of Sync${NC}"
        OUT_OF_SYNC=$((OUT_OF_SYNC + 1))
    else
        echo -e "${RED}❌ ${APP}: ${STATUS} / ${HEALTH}${NC}"
        DEGRADED=$((DEGRADED + 1))
    fi
done

echo ""
echo -e "${GREEN}Summary:${NC}"
echo -e "  Synced & Healthy: ${GREEN}${SYNCED}${NC}"
echo -e "  Out of Sync: ${YELLOW}${OUT_OF_SYNC}${NC}"
echo -e "  Degraded: ${RED}${DEGRADED}${NC}"