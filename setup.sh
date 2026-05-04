#!/bin/bash
set -euo pipefail

# =============================================================================
# LLM Log Analysis Platform — Vagrant + k3s + Qwen 3.5 7B (no Ollama)
# =============================================================================
# Target: MacBook Pro M1 Pro, 32GB RAM, VirtualBox + Vagrant
#
# What gets deployed:
#   - Vagrant VM with k3s Kubernetes cluster
#   - Qwen 3.5 10B (GGUF) via llama.cpp server — direct, no Ollama
#   - Qdrant vector database
#   - Sentence-transformers embedding service
#   - FastAPI RAG app for log analysis
#   - Sample log ingestion pipeline
#
# Resource budget:
#   Vagrant VM:        ~2 GB (base system)
#   k3s system:        ~1 GB
#   Qwen 3.5 10B:      ~12 GB RAM (Q4_K_M quantized + context)
#   Qdrant:            ~1 GB (vector storage + HNSW indexes)
#   Embeddings:        ~2 GB (sentence-transformers + batch processing)
#   RAG app:           ~512 MB (FastAPI + HTTP connections)
#   Ingestion job:     ~1 GB (temporary, during log processing)
#   Total:             ~19-20 GB (Host needs ≥24 GB allocated to VM)
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_HOSTNAME="llm-platform.local"
RANCHER_PASSWORD="SuperAdmin@123"

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 0: Preflight checks"
# ─────────────────────────────────────────────────────────────────────────────

# Check if running inside control plane VM
HOSTNAME=$(hostname)
if [[ "$HOSTNAME" != "llm-control.local" && "$HOSTNAME" != "llm-control" ]]; then
  err "This script must be run from the control plane VM. Run: vagrant ssh control && ./setup.sh"
fi

log "Running inside control plane VM (hostname: $HOSTNAME)"

# Check if k3s is installed and running
if ! command -v k3s &>/dev/null; then
  err "k3s not found. The control plane provisioning should have installed it."
fi

log "k3s is installed"

# Verify cluster has both nodes (with retry for automatic provisioning)
log "Checking cluster nodes..."
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

MAX_RETRIES=60
RETRY_COUNT=0
while ! kubectl get nodes 2>/dev/null | grep -q "llm-data"; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    log "Cluster nodes status:"
    kubectl get nodes 2>/dev/null || echo "kubectl not available yet"
    err "Data plane node not found after $MAX_RETRIES attempts. Ensure data VM is provisioned and joined."
  fi
  log "Waiting for data plane node to join... (attempt $RETRY_COUNT/$MAX_RETRIES, sleeping 10s)"
  sleep 10
done

log "Kubernetes cluster is ready with both nodes"
kubectl get nodes

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 1: Verify k3s cluster"
# ─────────────────────────────────────────────────────────────────────────────

log "Using k3s Kubernetes cluster (provided by Vagrant)"
kubectl cluster-info
log "Kubernetes cluster is ready"

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 2: Install Helm"
# ─────────────────────────────────────────────────────────────────────────────

if ! command -v helm &>/dev/null; then
  log "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  log "Helm installed"
else
  log "Helm already installed"
fi

# ─────────────────────────────────────────────────────────────────────────────

# cert-manager (Rancher dependency)
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update jetstack 2>/dev/null

if ! helm list -q -n cert-manager 2>/dev/null | grep -q "^cert-manager$"; then
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --set crds.enabled=true \
    --set webhook.replicaCount=1 \
    --set cainjector.replicaCount=1 \
    --set resources.requests.cpu=50m \
    --set resources.requests.memory=128Mi \
    --wait --timeout 600s || {
    warn "Helm install timed out, checking if cert-manager is running..."
    if kubectl get deployment cert-manager -n cert-manager 2>/dev/null | grep -q "1/1"; then
      log "cert-manager is running despite Helm timeout"
    else
      err "cert-manager installation failed"
    fi
  }
  log "cert-manager installed"
else
  log "cert-manager already installed"
fi

# Wait for cert-manager webhook to be ready before installing Rancher
log "Waiting for cert-manager webhook to be ready..."
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=180s || {
  warn "cert-manager webhook not ready, waiting additional 60 seconds..."
  sleep 60
}

# Rancher Server
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest 2>/dev/null || true
helm repo update rancher-latest 2>/dev/null

if ! helm list -n cattle-system 2>/dev/null | grep -q rancher; then
  # Disable ingress validation webhook to avoid certificate issues
  helm install rancher rancher-latest/rancher \
    --namespace cattle-system --create-namespace \
    --set hostname="$VM_HOSTNAME" \
    --set bootstrapPassword="$RANCHER_PASSWORD" \
    --set replicas=1 \
    --set ingress.tls.source=rancher \
    --set ingress.class=traefik \
    --set "ingress.extraAnnotations.kubernetes\.io/ingress\.allow-http-0=\"true\"" \
    --wait --timeout 300s || {
    warn "Helm install timed out, checking if Rancher is running..."
    if kubectl get deployment rancher -n cattle-system 2>/dev/null | grep -q "1/1"; then
      log "Rancher is running despite Helm timeout"
    else
      err "Rancher installation failed"
    fi
  }
  log "Rancher installed"
  log "URL:      https://$VM_HOSTNAME"
  log "Password: $RANCHER_PASSWORD"
else
  log "Rancher already installed"
fi

log "Waiting for Rancher rollout..."
kubectl -n cattle-system rollout status deploy/rancher --timeout=300s
log "Rancher is ready at https://$VM_HOSTNAME"

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 5: Build container images (no Ollama — raw llama.cpp)"
# ─────────────────────────────────────────────────────────────────────────────

log "Skipping image building on control plane — images are built on data plane"
log "Using images built during data plane provisioning"

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 6: Deploy the LLM platform stack"
# ─────────────────────────────────────────────────────────────────────────────

# Namespace
kubectl apply -f "$SCRIPT_DIR/manifests/00-namespace.yaml"

# Create ConfigMap from sample log files
kubectl create configmap sample-logs \
  --from-file="$SCRIPT_DIR/sample-logs/" \
  -n ai-platform \
  --dry-run=client -o yaml | kubectl apply -f -
log "Sample logs ConfigMap created"

# Qdrant
kubectl apply -f "$SCRIPT_DIR/manifests/01-qdrant.yaml"
log "Qdrant deployed"

# Qwen 3.5 — model download + inference server
kubectl apply -f "$SCRIPT_DIR/manifests/02-qwen3-server.yaml"
log "Qwen 3.5 model download started + server deployment created"

# Embedding server
kubectl apply -f "$SCRIPT_DIR/manifests/03-embedding-server.yaml"
log "Embedding server deployed"

# RAG app
kubectl apply -f "$SCRIPT_DIR/manifests/04-rag-app.yaml"
log "Log analysis app deployed"

# Ingress
kubectl apply -f "$SCRIPT_DIR/manifests/06-ingress.yaml"
log "Ingress configured"

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 7: Wait for services to be ready"
# ─────────────────────────────────────────────────────────────────────────────

log "Waiting for Qdrant..."
kubectl wait --for=condition=Available deployment/qdrant -n ai-platform --timeout=120s

log "Waiting for embedding server (first run downloads model ~80MB)..."
kubectl wait --for=condition=Available deployment/embedding-server -n ai-platform --timeout=600s 2>/dev/null || \
  warn "Embedding server still starting — check: kubectl logs -n ai-platform deploy/embedding-server -f"

log "Waiting for Qwen 3.5 model download (6.0GB, this takes time)..."

log "Waiting for Qwen 3.5 server (model loading takes 5-10 minutes)..."
kubectl wait --for=condition=Available deployment/qwen3-server -n ai-platform --timeout=1200s 2>/dev/null || \
  warn "Qwen 3.5 still loading — check: kubectl logs -n ai-platform deploy/qwen3-server -f"

log "Waiting for RAG app..."
kubectl wait --for=condition=Available deployment/log-analysis-app -n ai-platform --timeout=300s 2>/dev/null || \
  warn "RAG app still starting — check: kubectl logs -n ai-platform deploy/log-analysis-app -f"

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 8: Run log ingestion"
# ─────────────────────────────────────────────────────────────────────────────

# Delete previous job run if exists
kubectl delete job log-ingestion -n ai-platform --ignore-not-found 2>/dev/null

kubectl apply -f "$SCRIPT_DIR/manifests/05-ingestion-job.yaml"
log "Ingestion job started — processing sample logs..."

kubectl wait --for=condition=Complete job/log-ingestion -n ai-platform --timeout=300s 2>/dev/null && \
  log "Ingestion complete" || \
  warn "Ingestion still running — check: kubectl logs -n ai-platform job/log-ingestion -f"

# ─────────────────────────────────────────────────────────────────────────────
step "DONE — Platform is ready"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}┌──────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│  LLM Log Analysis Platform                              │${NC}"
echo -e "${GREEN}├──────────────────────────────────────────────────────────┤${NC}"
echo -e "${GREEN}│  Rancher UI:    https://$VM_HOSTNAME                      │${NC}"
echo -e "${GREEN}│  Chat UI:       http://logs.$VM_HOSTNAME                  │${NC}"
echo -e "${GREEN}│  RAG API:       http://logs.$VM_HOSTNAME/api/analyze      │${NC}"
echo -e "${GREEN}│  Qdrant:        kubectl port-forward svc/qdrant 6333     │${NC}"
echo -e "${GREEN}│  Qwen 3.5 API:  kubectl port-forward svc/qwen3-server    │${NC}"
echo -e "${GREEN}├──────────────────────────────────────────────────────────┤${NC}"
echo -e "${GREEN}│  Rancher password: $RANCHER_PASSWORD                     │${NC}"
echo -e "${GREEN}└──────────────────────────────────────────────────────────┘${NC}"
echo ""
echo "From host machine, access via:"
echo "  http://localhost:30080 (NodePort)"
echo "  Or add to /etc/hosts: $(hostname -I | awk '{print $1}') logs.llm-platform.local"
echo ""
echo "Test with:"
echo "  curl -X POST http://logs.$VM_HOSTNAME/api/analyze \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"question\": \"What errors are recurring in the logs?\"}'"
echo ""
echo "Monitor:"
echo "  kubectl get pods -n ai-platform -w"
echo "  kubectl logs -n ai-platform deploy/qwen3-server -f"
echo "  kubectl top pods -n ai-platform"
