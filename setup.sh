#!/bin/bash
set -euo pipefail

# =============================================================================
# LLM Log Analysis Platform — Vagrant + k3s + Qwen3 4B (no Ollama)
# =============================================================================
# Target: MacBook Pro M1 Pro, 32GB RAM, VirtualBox + Vagrant
#
# What gets deployed:
#   - Vagrant VM with k3s Kubernetes cluster
#   - Qwen3 4B (GGUF) via llama.cpp server — direct, no Ollama
#   - Qdrant vector database
#   - Sentence-transformers embedding service
#   - FastAPI RAG app for log analysis
#   - Sample log ingestion pipeline
#
# Resource budget:
#   Vagrant VM:        ~2 GB (base system)
#   k3s system:        ~1 GB
#   Qwen3 4B:          ~6 GB RAM (Q4_K_M quantized + context)
#   Qdrant:            ~1 GB (vector storage + HNSW indexes)
#   Embeddings:        ~2 GB (sentence-transformers + batch processing)
#   RAG app:           ~512 MB (FastAPI + HTTP connections)
#   Ingestion job:     ~1 GB (temporary, during log processing)
#   Monitoring:        ~1 GB (Prometheus, Grafana, node-exporter, kube-state-metrics)
#   Total:             ~20-21 GB (Host needs ≥24 GB allocated to VMs)
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RANCHER_HOSTNAME="rancher.localhost"
RANCHER_PASSWORD="SuperAdmin@123"

# Helm chart versions — pinned for reproducibility. Bumping any of these without
# verifying upgrade compatibility (CRDs, breaking changes) will break setup.
CERT_MANAGER_VERSION="v1.20.2"
RANCHER_VERSION="2.14.1"
INGRESS_NGINX_VERSION="4.15.1"

helm_repo_add_or_update() {
  local name="$1"
  local url="$2"
  helm repo add "$name" "$url" --force-update >/dev/null
}

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
if [ -r "${HOME}/.kube/config" ]; then
  export KUBECONFIG="${HOME}/.kube/config"
elif [ -r /etc/rancher/k3s/k3s.yaml ]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
else
  err "No readable kubeconfig found. Expected ${HOME}/.kube/config or /etc/rancher/k3s/k3s.yaml"
fi
log "Using kubeconfig: $KUBECONFIG"

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

# k3s installs Traefik by default unless the server was started with
# --disable=traefik. New VMs use that flag from vagrant-provision.sh; this block
# also cleans up older lab clusters so nginx remains the only ingress controller.
log "Ensuring bundled k3s Traefik is disabled..."
sudo mkdir -p /etc/rancher/k3s/config.yaml.d
printf "disable:\n  - traefik\n" | sudo tee /etc/rancher/k3s/config.yaml.d/10-disable-traefik.yaml >/dev/null

if [ -f /var/lib/rancher/k3s/server/manifests/traefik.yaml ]; then
  sudo mv /var/lib/rancher/k3s/server/manifests/traefik.yaml \
    /var/lib/rancher/k3s/server/manifests/traefik.yaml.disabled 2>/dev/null || \
    sudo rm -f /var/lib/rancher/k3s/server/manifests/traefik.yaml
fi
kubectl -n kube-system delete helmchart traefik --ignore-not-found=true 2>/dev/null || true
kubectl -n kube-system delete helmchart traefik-crd --ignore-not-found=true 2>/dev/null || true
kubectl -n kube-system delete helmchartconfig traefik --ignore-not-found=true 2>/dev/null || true
for release in traefik traefik-crd; do
  if helm list -n kube-system -q 2>/dev/null | grep -qx "$release"; then
    helm uninstall "$release" -n kube-system || warn "Could not uninstall $release Helm release; continuing with nginx setup"
  fi
done
kubectl -n kube-system delete service traefik --ignore-not-found=true 2>/dev/null || true
kubectl -n kube-system delete deployment traefik --ignore-not-found=true 2>/dev/null || true
kubectl delete ingressclass traefik --ignore-not-found=true 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────

# cert-manager (Rancher dependency)
helm_repo_add_or_update jetstack https://charts.jetstack.io
helm repo update jetstack

# `upgrade --install` is the idempotent form — same behavior on first run and
# re-runs, no install/list/grep dance, and re-runs reconcile drift.
log "Installing/upgrading cert-manager ${CERT_MANAGER_VERSION}..."
helm upgrade --install cert-manager jetstack/cert-manager \
  --version "$CERT_MANAGER_VERSION" \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --set webhook.replicaCount=1 \
  --set cainjector.replicaCount=1 \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=128Mi \
  --wait --timeout 600s || err "cert-manager helm upgrade failed — check: helm history cert-manager -n cert-manager"

# Independently verify all three cert-manager deployments are Available before
# anything that depends on the admission webhook (e.g. Rancher) tries to use it.
# `helm --wait` only waits for the chart's own readiness gates and has produced
# false positives in this lab when the webhook lagged behind the controller.
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do
  log "Waiting for $d to be Available..."
  kubectl wait --for=condition=Available "deployment/$d" -n cert-manager --timeout=300s || \
    err "$d not Available — check: kubectl get pods -n cert-manager"
done

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 3: Install Nginx Ingress Controller"
# ─────────────────────────────────────────────────────────────────────────────

helm_repo_add_or_update ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update ingress-nginx

# Run the controller as a DaemonSet so every node serves NodePort 30080 directly.
# Single-replica Deployment goes dark if the hosting node restarts; DaemonSet
# survives a node hiccup (k3s coming back, kubelet bounce, etc.).
#
# Notes:
# - Both http (30080) and https (30443) NodePorts are pinned so they don't drift
#   on reinstall; Vagrant port-forwarding depends on stable values.
# - Traefik is disabled, so nginx is marked as the cluster's default class.
#   Our own Ingress manifests still set ingressClassName: nginx explicitly.
log "Installing/upgrading ingress-nginx ${INGRESS_NGINX_VERSION} (DaemonSet)..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --version "$INGRESS_NGINX_VERSION" \
  --namespace ingress-nginx --create-namespace \
  --set controller.kind=DaemonSet \
  --set controller.replicaCount=null \
  --set controller.service.type=NodePort \
  --set controller.service.nodePorts.http=30080 \
  --set controller.service.nodePorts.https=30443 \
  --set controller.ingressClassResource.name=nginx \
  --set controller.ingressClassResource.default=true \
  --wait --timeout 300s || err "ingress-nginx helm upgrade failed — check: helm history ingress-nginx -n ingress-nginx"

kubectl rollout status ds/ingress-nginx-controller -n ingress-nginx --timeout=300s || \
  err "ingress-nginx DaemonSet did not become ready — check: kubectl get pods -n ingress-nginx"

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 4: Install Rancher Server"
# ─────────────────────────────────────────────────────────────────────────────

helm_repo_add_or_update rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update rancher-latest

log "Installing/upgrading Rancher ${RANCHER_VERSION}..."
# Inject Local SSL Certificates if generated by mkcert in deploy.sh
if [ -f /vagrant/certs/local-cert.pem ] && [ -f /vagrant/certs/local-key.pem ]; then
  log "Found local SSL certificates in /vagrant/certs. Creating Kubernetes TLS secrets..."

  kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret tls tls-rancher-ingress \
    --cert=/vagrant/certs/local-cert.pem \
    --key=/vagrant/certs/local-key.pem \
    -n cattle-system --dry-run=client -o yaml | kubectl apply -f -

  kubectl create namespace ai-platform --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret tls local-tls-cert \
    --cert=/vagrant/certs/local-cert.pem \
    --key=/vagrant/certs/local-key.pem \
    -n ai-platform --dry-run=client -o yaml | kubectl apply -f -

  kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret tls local-tls-cert \
    --cert=/vagrant/certs/local-cert.pem \
    --key=/vagrant/certs/local-key.pem \
    -n monitoring --dry-run=client -o yaml | kubectl apply -f -

  RANCHER_TLS_SOURCE="secret"
else
  warn "No local SSL certificates found in /vagrant/certs (run deploy.sh). Rancher will use cert-manager (self-signed)."
  RANCHER_TLS_SOURCE="rancher"
fi

helm upgrade --install rancher rancher-latest/rancher \
  --version "$RANCHER_VERSION" \
  --namespace cattle-system --create-namespace \
  --set hostname="$RANCHER_HOSTNAME" \
  --set bootstrapPassword="$RANCHER_PASSWORD" \
  --set replicas=1 \
  --set ingress.tls.source=$RANCHER_TLS_SOURCE \
  --set ingress.ingressClassName=nginx \
  --set ingress.class=nginx \
  --set-string "ingress.extraAnnotations.nginx\.ingress\.kubernetes\.io/proxy-connect-timeout=30" \
  --set-string "ingress.extraAnnotations.nginx\.ingress\.kubernetes\.io/proxy-read-timeout=1800" \
  --set-string "ingress.extraAnnotations.nginx\.ingress\.kubernetes\.io/proxy-send-timeout=1800" \
  --wait --timeout 600s || err "Rancher helm upgrade failed — check: helm history rancher -n cattle-system"

log "Waiting for Rancher main deployment to be Available..."
kubectl -n cattle-system rollout status deploy/rancher --timeout=600s || \
  err "deploy/rancher did not roll out — check: kubectl logs -n cattle-system deploy/rancher"

# rancher-webhook is created BY the rancher controller after install (not by the
# chart), so it's normal for it to not exist immediately. Bound the wait so a
# stuck Rancher doesn't hang setup.sh forever.
log "Waiting for rancher-webhook deployment to appear (max 5 min)..."
for _ in {1..60}; do
  kubectl get deploy -n cattle-system rancher-webhook >/dev/null 2>&1 && break
  sleep 5
done
kubectl get deploy -n cattle-system rancher-webhook >/dev/null 2>&1 || \
  err "rancher-webhook never appeared — Rancher likely failed to bootstrap. Check: kubectl logs -n cattle-system deploy/rancher"

kubectl -n cattle-system rollout status deploy/rancher-webhook --timeout=300s || \
  err "rancher-webhook did not roll out — check: kubectl logs -n cattle-system deploy/rancher-webhook"

log "Rancher is ready at https://$RANCHER_HOSTNAME:8443"

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 5: Deploy monitoring stack"
# ─────────────────────────────────────────────────────────────────────────────

kubectl apply -f "$SCRIPT_DIR/manifests/07-monitoring.yaml"
log "Prometheus, Grafana, node-exporter, and kube-state-metrics deployed"

log "Waiting for monitoring stack..."
kubectl -n monitoring rollout status daemonset/node-exporter --timeout=600s || \
  err "node-exporter failed to become ready. Check: kubectl get pods -n monitoring"
kubectl -n monitoring rollout status deploy/kube-state-metrics --timeout=600s || \
  err "kube-state-metrics failed to become ready. Check: kubectl logs -n monitoring deploy/kube-state-metrics"
kubectl -n monitoring rollout status deploy/prometheus --timeout=600s || \
  err "Prometheus failed to become ready. Check: kubectl logs -n monitoring deploy/prometheus"
kubectl -n monitoring rollout status deploy/grafana --timeout=600s || \
  err "Grafana failed to become ready. Check: kubectl logs -n monitoring deploy/grafana"

log "Monitoring access from host: Prometheus http://localhost:30090, Grafana http://localhost:30300"

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 6: Build container images (no Ollama — raw llama.cpp)"
# ─────────────────────────────────────────────────────────────────────────────

log "Skipping image building on control plane — images are pre-built on the host"
log "Using images imported into k3s containerd during VM provisioning"

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 7: Deploy the LLM platform stack"
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

# Qwen3 4B — model download + inference server
kubectl apply -f "$SCRIPT_DIR/manifests/02-qwen3-server.yaml"
log "Qwen3 4B model download started + server deployment created"

# Embedding server
kubectl apply -f "$SCRIPT_DIR/manifests/03-embedding-server.yaml"
log "Embedding server deployed"

# RAG app
kubectl apply -f "$SCRIPT_DIR/manifests/04-rag-app.yaml"
log "Log analysis app deployed"

# Fluent Bit DaemonSet — streams live cluster logs into the rag-app /api/ingest
# endpoint, which embeds them and upserts vectors into Qdrant. Applied after the
# rag-app deploy because the HTTP output targets log-analysis-app's Service.
kubectl apply -f "$SCRIPT_DIR/manifests/08-fluent-bit.yaml"
log "Fluent Bit live log ingestion deployed"

# Ingress
kubectl apply -f "$SCRIPT_DIR/manifests/06-ingress.yaml"
log "Ingress configured"

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 8: Wait for services to be ready"
# ─────────────────────────────────────────────────────────────────────────────

log "Waiting for Qdrant..."
kubectl wait --for=condition=Available deployment/qdrant -n ai-platform --timeout=120s

log "Waiting for embedding server (first run downloads model ~80MB)..."
kubectl wait --for=condition=Available deployment/embedding-server -n ai-platform --timeout=600s 2>/dev/null || \
  warn "Embedding server still starting — check: kubectl logs -n ai-platform deploy/embedding-server -f"

log "Waiting for Qwen3 4B model download (GGUF, this takes time)..."

log "Waiting for Qwen3 4B server (model loading takes 5-10 minutes)..."
kubectl wait --for=condition=Available deployment/qwen3-server -n ai-platform --timeout=1200s 2>/dev/null || \
  warn "Qwen3 4B still loading — check: kubectl logs -n ai-platform deploy/qwen3-server -f"

log "Waiting for RAG app..."
kubectl wait --for=condition=Available deployment/log-analysis-app -n ai-platform --timeout=300s 2>/dev/null || \
  warn "RAG app still starting — check: kubectl logs -n ai-platform deploy/log-analysis-app -f"

log "Waiting for Fluent Bit DaemonSet..."
kubectl rollout status daemonset/fluent-bit -n ai-platform --timeout=180s 2>/dev/null || \
  warn "Fluent Bit still starting — check: kubectl logs -n ai-platform -l app.kubernetes.io/name=fluent-bit -f"

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 9: Run log ingestion"
# ─────────────────────────────────────────────────────────────────────────────

# Delete previous job run if exists
kubectl delete job log-ingestion -n ai-platform --ignore-not-found 2>/dev/null

kubectl apply -f "$SCRIPT_DIR/manifests/05-ingestion-job.yaml"
log "Ingestion job started — processing sample logs..."

if kubectl wait --for=condition=Complete job/log-ingestion -n ai-platform --timeout=300s 2>/dev/null; then
  log "Ingestion complete"
else
  warn "Ingestion still running — check: kubectl logs -n ai-platform job/log-ingestion -f"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "Helm release health check"
# ─────────────────────────────────────────────────────────────────────────────

# Final assertion: every chart this script installs must be in 'deployed' state.
# A 'failed', 'pending-install', or 'pending-upgrade' release here means an
# earlier silent failure — surface it now rather than ship a broken cluster.
log "Verifying helm releases..."
bad_releases=""
for managed_release in \
  "cert-manager cert-manager" \
  "cattle-system rancher" \
  "ingress-nginx ingress-nginx"; do
  namespace="${managed_release%% *}"
  release="${managed_release#* }"
  status=$(helm status "$release" -n "$namespace" 2>/dev/null | awk -F': ' '$1 == "STATUS" { print $2 }')
  if [ "$status" != "deployed" ]; then
    bad_releases="${bad_releases}${namespace}/${release}: ${status:-missing}\n"
  fi
done
if [ -n "$bad_releases" ]; then
  err "Helm releases not in 'deployed' state:\n$bad_releases"
fi
helm list -A --filter '^(cert-manager|rancher|ingress-nginx)$' || true
log "All managed helm releases are healthy"

if helm list -n kube-system -q 2>/dev/null | grep -Eq "^traefik(-crd)?$"; then
  err "Traefik Helm release still exists after nginx-only setup — check: helm list -n kube-system"
fi
if kubectl get ingressclass traefik >/dev/null 2>&1; then
  err "Traefik IngressClass still exists after nginx-only setup"
fi
if kubectl -n kube-system get deploy traefik >/dev/null 2>&1 || \
   kubectl -n kube-system get svc traefik >/dev/null 2>&1; then
  err "Traefik workload/service still exists after nginx-only setup"
fi
log "Traefik is disabled and no Traefik ingress path remains"

# ─────────────────────────────────────────────────────────────────────────────
step "DONE — Platform is ready"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}┌──────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│  LLM Log Analysis Platform (HTTPS Secured via mkcert)   │${NC}"
echo -e "${GREEN}├──────────────────────────────────────────────────────────┤${NC}"
echo -e "${GREEN}│  Rancher UI:    https://rancher.localhost:8443           │${NC}"
echo -e "${GREEN}│  Chat UI:       https://chat.localhost:8443              │${NC}"
echo -e "${GREEN}│  Grafana:       https://grafana.localhost:8443           │${NC}"
echo -e "${GREEN}│  Prometheus:    https://prometheus.localhost:8443        │${NC}"
echo -e "${GREEN}│  Qdrant:        kubectl port-forward svc/qdrant 6333     │${NC}"
echo -e "${GREEN}│  Qwen3 4B API:  kubectl port-forward svc/qwen3-server 8000│${NC}"
echo -e "${GREEN}├──────────────────────────────────────────────────────────┤${NC}"
echo -e "${GREEN}│  Rancher password: $RANCHER_PASSWORD                     │${NC}"
echo -e "${GREEN}│  Grafana login:    admin / $RANCHER_PASSWORD             │${NC}"
echo -e "${GREEN}└──────────────────────────────────────────────────────────┘${NC}"
echo ""
echo "Note: Vagrant forwards guest HTTPS 443 to host 8443."
echo "If domains do not resolve, add them to your host's /etc/hosts file:"
echo "127.0.0.1 rancher.localhost chat.localhost grafana.localhost prometheus.localhost"
echo ""
echo "Test with:"
echo "  curl -k -X POST https://chat.localhost:8443/api/analyze \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"question\": \"What errors are recurring in the logs?\"}'"
echo ""
echo "Monitor:"
echo "  kubectl get pods -n ai-platform -w"
echo "  kubectl get pods -n monitoring -w"
echo "  kubectl logs -n ai-platform deploy/qwen3-server -f"
echo "  kubectl top pods -n ai-platform"
