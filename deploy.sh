#!/bin/bash
set -euo pipefail

# =============================================================================
# LLM Platform - Multi-VM Deployment Helper
# =============================================================================
# This script orchestrates the two-VM deployment with resource isolation:
# - Control plane: k3s management (4GB RAM, 2 CPU)
# - Data plane: LLM workloads (20GB RAM, 4 CPU)
#
# Note: You can also just run 'vagrant up' for automatic deployment.
#       This script provides more control and better output formatting.
#
# Usage:
#   ./deploy.sh              # Deploy both VMs with progress output
#   ./deploy.sh --redeploy   # Destroy VMs and redeploy from scratch
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; }
step()  { echo -e "\n${CYAN}▶▶▶ $1 ${CYAN}▶▶▶${NC}"; }

REDEPLOY=false
if [[ "${1:-}" == "--redeploy" ]]; then
  REDEPLOY=true
fi

# ─────────────────────────────────────────────────────────────────────────────
step "LLM Platform Deployment"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "This will deploy:"
echo "  • Control plane VM: k3s Kubernetes + management (Ubuntu 24.04)"
echo "  • Data plane VM: LLM workloads with resource isolation"
echo "  • Qwen3 4B inference server (llama.cpp)"
echo "  • Qdrant vector database"
echo "  • Embedding service (sentence-transformers)"
echo "  • RAG application (FastAPI)"
echo "  • Prometheus metrics collection"
echo "  • Grafana dashboards"
echo "  • Rancher management UI"
echo ""
echo "Resource requirements:"
echo "  • Control plane: 4GB RAM, 2 CPU cores"
echo "  • Data plane: 20GB RAM, 4 CPU cores"
echo "  • Total host RAM needed: ≥24GB"
echo "  • Deployment time: ~15-20 minutes"
echo ""

if [ "$REDEPLOY" = true ]; then
  echo -e "${YELLOW}⚠ REDEPLOY MODE: Will destroy existing VMs${NC}"
  echo "Press Ctrl+C to cancel, or wait 5 seconds to continue..."
  sleep 5

  step "Destroying existing VMs"
  vagrant destroy -f
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Pre-building Docker Images"
# ─────────────────────────────────────────────────────────────────────────────
log "Docker images built and prepared in ./prebuilt-images/"


# ─────────────────────────────────────────────────────────────────────────────
step "Starting Multi-VM Deployment"
# ─────────────────────────────────────────────────────────────────────────────

echo "Bringing up control plane VM..."
echo ""

# Start control plane first
vagrant up control

echo ""
echo "Bringing up data plane VM..."
echo ""

# Start data plane
vagrant up data

# ─────────────────────────────────────────────────────────────────────────────
step "Deploying LLM Platform Stack"
# ─────────────────────────────────────────────────────────────────────────────

echo "Waiting for data plane to be ready..."
echo ""

# Wait for data plane node to be ready
vagrant ssh control --command "bash -c '
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
echo \"Waiting for data plane node to join cluster...\"
MAX_WAIT=120
WAIT_COUNT=0
while ! kubectl get nodes 2>/dev/null | grep -q \"llm-data.*Ready\"; do
  WAIT_COUNT=$((WAIT_COUNT + 1))
  if [ \$WAIT_COUNT -ge \$MAX_WAIT ]; then
    echo \"Timeout waiting for data plane. Current nodes:\"
    kubectl get nodes 2>/dev/null || echo \"kubectl not ready\"
    exit 1
  fi
  echo \"Waiting for data plane node... (\$WAIT_COUNT/\$MAX_WAIT, 10s)\"
  sleep 10
done
echo \"Data plane is ready!\"
kubectl get nodes
'"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
step "Deployment Complete!"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "  LLM Platform Successfully Deployed!"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log ""
log "Access Points:"
log "  - Chat UI:     http://localhost:30080"
log "  - Grafana:     http://localhost:30300 (admin / SuperAdmin@123)"
log "  - Prometheus:  http://localhost:30090"
log "  - Rancher UI:  https://rancher.localhost:8443"
log "  - Rancher PW:  SuperAdmin@123"
log ""
log "Monitor with:"
log "  vagrant ssh control --command 'kubectl get pods -n ai-platform'"
log "  vagrant ssh control --command 'kubectl get pods -n monitoring'"
log "  vagrant ssh data --command 'kubectl logs -n ai-platform -l app=log-analysis-app -f'"
log ""
log "Manage VMs:"
log "  ./build-images-local.sh  # Pre-build Docker images before deployment"
log "  vagrant halt             # Stop both VMs"
log "  vagrant up               # Start both VMs"
log "  vagrant up control       # Start control plane only"
log "  vagrant up data          # Start data plane only"
log "  vagrant destroy          # Remove both VMs"
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
