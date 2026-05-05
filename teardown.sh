#!/bin/bash
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

echo -e "${YELLOW}This will destroy the entire LLM platform:${NC}"
echo "  - Kubernetes namespace 'ai-platform' (all workloads, all PVCs)"
echo "  - Kubernetes namespace 'monitoring' (Prometheus, Grafana, exporters)"
echo "  - ArgoCD, cert-manager, ingress-nginx, and Rancher Server"
echo ""
read -p "Are you sure? (y/N) " -n 1 -r; echo

if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Cancelled."
  exit 0
fi

echo -e "${GREEN}[+]${NC} Deleting namespaces..."
kubectl delete namespace ai-platform --ignore-not-found 2>/dev/null || echo "  Namespace already gone"
kubectl delete namespace monitoring --ignore-not-found 2>/dev/null || echo "  Namespace already gone"
kubectl delete namespace argocd --ignore-not-found 2>/dev/null || echo "  Namespace already gone"
kubectl delete namespace ingress-nginx --ignore-not-found 2>/dev/null || echo "  Namespace already gone"
kubectl delete namespace cert-manager --ignore-not-found 2>/dev/null || echo "  Namespace already gone"
kubectl delete namespace cattle-system --ignore-not-found 2>/dev/null || echo "  Namespace already gone"

echo ""
echo -e "${GREEN}Done. Kubernetes resources cleaned up.${NC}"
echo "To rebuild infrastructure: ./setup.sh"
echo "To destroy VM: vagrant destroy"
