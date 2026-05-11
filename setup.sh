#!/bin/bash
set -euo pipefail

# =============================================================================
# LLM Platform Infrastructure — Bootstrap (ArgoCD App of Apps)
# =============================================================================
# Target: MacBook Pro M1 Pro, 32GB RAM, VirtualBox + Vagrant
#
# What gets installed here (bootstrap layer — the irreducible minimum):
#   - k3s Kubernetes cluster validation
#   - Helm
#   - Traefik cleanup (k3s default, replaced by ArgoCD-managed ingress-nginx)
#   - Namespaces and local TLS secrets (mkcert certs from deploy.sh)
#   - ArgoCD
#
# Everything else is managed by ArgoCD via the App of Apps pattern:
#   cert-manager  (sync wave 0)
#   ingress-nginx (sync wave 1)
#   Rancher       (sync wave 2)
#   AI platform + monitoring workloads (sync wave 3)
#
# The root Application is defined in the GitOps repository:
#   https://github.com/anasgrt/LLM-PLATFORM-POC-ARGOCD  →  deploy/platform/
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

ARGOCD_PASSWORD="SuperAdmin@123"
ARGOCD_CHART_VERSION="7.8.27"   # argo-cd chart 7.8.27 ⇒ ArgoCD v2.14.10

ROOT_APP_URL="https://raw.githubusercontent.com/anasgrt/LLM-PLATFORM-POC-ARGOCD/main/argocd/root.yaml"

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 0: Preflight checks"
# ─────────────────────────────────────────────────────────────────────────────

HOSTNAME=$(hostname)
if [[ "$HOSTNAME" != "llm-control.local" && "$HOSTNAME" != "llm-control" ]]; then
  err "This script must be run from the control plane VM. Run: vagrant ssh control && ./setup.sh"
fi

log "Running inside control plane VM (hostname: $HOSTNAME)"

if ! command -v k3s &>/dev/null; then
  err "k3s not found. The control plane provisioning should have installed it."
fi

log "k3s is installed"

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
step "STEP 2: Install Helm & remove Traefik"
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
    helm uninstall "$release" -n kube-system || warn "Could not uninstall $release Helm release; continuing"
  fi
done
kubectl -n kube-system delete service traefik --ignore-not-found=true 2>/dev/null || true
kubectl -n kube-system delete deployment traefik --ignore-not-found=true 2>/dev/null || true
kubectl delete ingressclass traefik --ignore-not-found=true 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 3: Prepare namespaces and TLS secrets"
# ─────────────────────────────────────────────────────────────────────────────

# Pre-create namespaces that need TLS secrets from local mkcert certificates.
# ArgoCD Applications also set CreateNamespace=true as a fallback, but the TLS
# secrets must exist before the Helm charts that reference them are installed.
for ns in cattle-system ingress-nginx cert-manager argocd ai-platform monitoring; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

if [ -f /vagrant/certs/local-cert.pem ] && [ -f /vagrant/certs/local-key.pem ]; then
  log "Found local SSL certificates in /vagrant/certs. Creating TLS secrets..."

  # Rancher expects its TLS secret named tls-rancher-ingress
  kubectl create secret tls tls-rancher-ingress \
    --cert=/vagrant/certs/local-cert.pem \
    --key=/vagrant/certs/local-key.pem \
    -n cattle-system --dry-run=client -o yaml | kubectl apply -f -

  # Workload and monitoring ingresses use local-tls-cert
  for ns in argocd ai-platform monitoring; do
    kubectl create secret tls local-tls-cert \
      --cert=/vagrant/certs/local-cert.pem \
      --key=/vagrant/certs/local-key.pem \
      -n "$ns" --dry-run=client -o yaml | kubectl apply -f -
  done

  log "Local TLS secrets prepared for all namespaces"
else
  warn "No local SSL certificates found in /vagrant/certs (run deploy.sh)."
  warn "Rancher will fall back to cert-manager self-signed certs."
  warn "Workload ingresses will need TLS secrets created later."
fi

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 4: Install ArgoCD"
# ─────────────────────────────────────────────────────────────────────────────

helm repo add argo https://argoproj.github.io/argo-helm --force-update >/dev/null
helm repo update argo

# Pin the admin password by passing a bcrypt hash to the chart.
if ! command -v htpasswd >/dev/null; then
  log "Installing apache2-utils for bcrypt password hashing..."
  sudo apt-get update -qq && sudo apt-get install -y -qq apache2-utils
fi
ARGOCD_PASSWORD_BCRYPT=$(htpasswd -nbBC 10 "" "$ARGOCD_PASSWORD" | tr -d ':\n' | sed 's|^\$2y|\$2a|')
ARGOCD_PASSWORD_MTIME=$(date -u +%FT%TZ)

ARGOCD_VALUES=/tmp/argocd-values.yaml
cat > "$ARGOCD_VALUES" <<EOF
global:
  domain: argocd.localhost

configs:
  params:
    server.insecure: true
    controller.diff.server.side: "true"
  secret:
    argocdServerAdminPasswordMtime: "$ARGOCD_PASSWORD_MTIME"
EOF
printf "    argocdServerAdminPassword: '%s'\n" "$ARGOCD_PASSWORD_BCRYPT" >> "$ARGOCD_VALUES"

cat >> "$ARGOCD_VALUES" <<EOF

server:
  ingress:
    enabled: true
    ingressClassName: nginx
    hostname: argocd.localhost
EOF
if [ -f /vagrant/certs/local-cert.pem ] && [ -f /vagrant/certs/local-key.pem ]; then
  cat >> "$ARGOCD_VALUES" <<EOF
    tls:
      - secretName: local-tls-cert
        hosts:
          - argocd.localhost
EOF
else
  cat >> "$ARGOCD_VALUES" <<EOF
    tls: true
EOF
fi

log "Installing/upgrading ArgoCD (chart ${ARGOCD_CHART_VERSION})..."
helm upgrade --install argocd argo/argo-cd \
  --version "$ARGOCD_CHART_VERSION" \
  --namespace argocd \
  --values "$ARGOCD_VALUES" \
  --wait --timeout 600s || err "argocd helm upgrade failed — check: helm history argocd -n argocd"

log "Waiting for ArgoCD components to roll out..."
for d in argocd-server argocd-repo-server argocd-applicationset-controller argocd-notifications-controller argocd-redis argocd-dex-server; do
  kubectl get deploy "$d" -n argocd >/dev/null 2>&1 || continue
  kubectl -n argocd rollout status deploy/"$d" --timeout=300s 2>/dev/null || \
    warn "ArgoCD $d not yet rolled out — check: kubectl get pods -n argocd"
done
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=300s 2>/dev/null || \
  warn "argocd-application-controller not yet rolled out"

log "ArgoCD ready at https://argocd.localhost:8443"
log "Login: admin / $ARGOCD_PASSWORD"

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 5: Apply root App of Apps"
# ─────────────────────────────────────────────────────────────────────────────

kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s

log "Applying root App of Apps from GitOps repository..."
kubectl apply -f "$ROOT_APP_URL"
log "Root Application submitted — ArgoCD will now cascade-install:"
log "  Wave 0: cert-manager"
log "  Wave 1: ingress-nginx"
log "  Wave 2: Rancher"
log "  Wave 3: AI platform + monitoring workloads"

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 6: Health check"
# ─────────────────────────────────────────────────────────────────────────────

# Verify ArgoCD helm release is healthy (the only chart this script installs).
argocd_status=$(helm status argocd -n argocd 2>/dev/null | awk -F': ' '$1 == "STATUS" { print $2 }')
if [ "$argocd_status" != "deployed" ]; then
  err "ArgoCD helm release not in 'deployed' state: ${argocd_status:-missing}"
fi
log "ArgoCD helm release is healthy"

if helm list -n kube-system -q 2>/dev/null | grep -Eq "^traefik(-crd)?$"; then
  err "Traefik Helm release still exists after cleanup"
fi
if kubectl get ingressclass traefik >/dev/null 2>&1; then
  err "Traefik IngressClass still exists after cleanup"
fi
log "Traefik is disabled and no Traefik ingress path remains"

# ─────────────────────────────────────────────────────────────────────────────
step "DONE — Bootstrap complete"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}┌──────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│  LLM Platform Bootstrap Complete (App of Apps)           │${NC}"
echo -e "${GREEN}├──────────────────────────────────────────────────────────┤${NC}"
echo -e "${GREEN}│  ArgoCD UI:     https://argocd.localhost:8443            │${NC}"
echo -e "${GREEN}│  ArgoCD login:  admin / $ARGOCD_PASSWORD                 │${NC}"
echo -e "${GREEN}├──────────────────────────────────────────────────────────┤${NC}"
echo -e "${GREEN}│  ArgoCD is now installing (sync waves):                  │${NC}"
echo -e "${GREEN}│    0: cert-manager                                      │${NC}"
echo -e "${GREEN}│    1: ingress-nginx                                     │${NC}"
echo -e "${GREEN}│    2: Rancher (https://rancher.localhost:8443)           │${NC}"
echo -e "${GREEN}│    3: AI workloads + monitoring                          │${NC}"
echo -e "${GREEN}└──────────────────────────────────────────────────────────┘${NC}"
echo ""
echo "Note: Vagrant forwards guest HTTPS 443 to host 8443."
echo "If domains do not resolve, add them to your host's /etc/hosts file:"
echo "127.0.0.1 rancher.localhost chat.localhost grafana.localhost prometheus.localhost argocd.localhost"
echo ""
echo "After ArgoCD finishes all sync waves, test with:"
echo "  curl -k -X POST https://chat.localhost:8443/api/analyze \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"question\": \"What errors are recurring in the logs?\"}'"
echo ""
echo "Monitor sync progress:"
echo "  kubectl get applications -n argocd"
echo "  kubectl get pods -n ai-platform -w"
echo "  kubectl get pods -n monitoring -w"
