#!/bin/bash
set -euo pipefail

# =============================================================================
# LLM Platform - Multi-VM Infrastructure Helper
# =============================================================================
# This script orchestrates the two-VM deployment with resource isolation:
# - Control plane: k3s management (4GB RAM, 2 CPU)
# - Data plane: worker capacity for ArgoCD-managed workloads (12GB RAM, 4 CPU)
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
step "LLM Platform Infrastructure Deployment"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "This will deploy:"
echo "  • Control plane VM: k3s Kubernetes + management (Ubuntu 24.04)"
echo "  • Data plane VM: worker capacity for ArgoCD-managed workloads"
echo "  • cert-manager, ingress-nginx, Rancher, and ArgoCD"
echo ""
echo "Resource requirements:"
echo "  • Control plane: 4GB RAM, 2 CPU cores"
echo "  • Data plane: 12GB RAM, 4 CPU cores"
echo "  • Total host RAM needed: ≥16GB"
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
step "Setting up Local SSL Certificates (mkcert)"
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v mkcert &> /dev/null; then
  log "Installing mkcert to generate trusted local SSL certificates..."
  if [[ "$OSTYPE" == "darwin"* ]] && command -v brew &> /dev/null; then
    log "macOS detected: Installing via Homebrew..."
    brew install mkcert nss || echo "Failed to install mkcert."
  elif command -v apt-get &> /dev/null; then
    log "Debian/Ubuntu host detected: Installing via apt-get..."
    sudo apt-get update && sudo apt-get install -y libnss3-tools mkcert || echo "Failed to install mkcert."
  else
    warn "Package manager not found. Please install mkcert manually for your OS."
  fi
fi

if command -v mkcert &> /dev/null; then
  # Initialize mkcert (creates and installs the local CA in the host's trust store)
  mkcert -install

  mkdir -p certs
  log "Generating wildcard/SAN SSL certificates for local domains..."
  cd certs
  mkcert -cert-file local-cert.pem -key-file local-key.pem \
    "localhost" "rancher.localhost" "argocd.localhost" "chat.localhost" "grafana.localhost" "prometheus.localhost"
  cd ..
else
  warn "Using self-signed certificates as mkcert is not available."
  mkdir -p certs
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout certs/local-key.pem \
    -out certs/local-cert.pem \
    -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,DNS:rancher.localhost,DNS:argocd.localhost,DNS:chat.localhost,DNS:grafana.localhost,DNS:prometheus.localhost"
fi


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
step "Infrastructure Complete!"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log "  LLM Platform Infrastructure Successfully Deployed!"
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log ""
log "ArgoCD is cascade-installing the full stack via App of Apps:"
log "  Wave 0: cert-manager"
log "  Wave 1: ingress-nginx"
log "  Wave 2: Rancher"
log "  Wave 3: AI platform + monitoring workloads"
log ""
log "Access Points (HTTPS Secured):"
log "  - ArgoCD UI:   https://argocd.localhost:8443 (admin / SuperAdmin@123)"
log "  - Rancher UI:  https://rancher.localhost:8443 (available after wave 2)"
log ""
log "(Note: Port 8443 is used because Vagrant forwards guest 443 to host 8443)"
log ""
log "Workload URLs (available after wave 3 sync):"
log "  - Chat UI:     https://chat.localhost:8443"
log "  - Grafana:     https://grafana.localhost:8443 (admin / SuperAdmin@123)"
log "  - Prometheus:  https://prometheus.localhost:8443"
log ""
log "Monitor sync progress:"
log "  vagrant ssh control --command 'kubectl get applications -n argocd'"
log "  vagrant ssh control --command 'kubectl get pods -n ai-platform'"
log "  vagrant ssh control --command 'kubectl get pods -n monitoring'"
log ""
log "Manage VMs:"
log "  vagrant halt             # Stop both VMs"
log "  vagrant up               # Start both VMs"
log "  vagrant up control       # Start control plane only"
log "  vagrant up data          # Start data plane only"
log "  vagrant destroy          # Remove both VMs"
log ""
log "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
