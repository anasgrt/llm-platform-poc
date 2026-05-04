#!/bin/bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo -e "${YELLOW}This will destroy the entire LLM platform:${NC}"
echo "  - Kubernetes namespace 'ai-platform' (all workloads, all PVCs)"
echo "  - Ingress controller, cert-manager, Rancher Server"
echo "  - Docker images"
echo ""
read -p "Are you sure? (y/N) " -n 1 -r; echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Cancelled."
  exit 0
fi

echo -e "${GREEN}[+]${NC} Deleting namespaces..."
kubectl delete namespace ai-platform --ignore-not-found 2>/dev/null || echo "  Namespace already gone"
kubectl delete namespace ingress-nginx --ignore-not-found 2>/dev/null || echo "  Namespace already gone"
kubectl delete namespace cert-manager --ignore-not-found 2>/dev/null || echo "  Namespace already gone"
kubectl delete namespace cattle-system --ignore-not-found 2>/dev/null || echo "  Namespace already gone"

echo -e "${GREEN}[+]${NC} Removing Docker images..."
for img in qwen3-server:latest embedding-server:latest rag-app:latest ingestion:latest; do
  docker rmi "$img" 2>/dev/null || true
done

echo -e "${GREEN}[+]${NC} Pruning dangling images..."
docker image prune -f 2>/dev/null

echo ""
echo -e "${GREEN}Done. Kubernetes resources cleaned up.${NC}"
echo "To rebuild: ./setup.sh"
echo "To destroy VM: vagrant destroy"
