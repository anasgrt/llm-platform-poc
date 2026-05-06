#!/bin/bash
set -euo pipefail

# =============================================================================
# LLM Platform Infrastructure — Vagrant + k3s + Rancher + ArgoCD
# =============================================================================
# Target: MacBook Pro M1 Pro, 32GB RAM, VirtualBox + Vagrant
#
# What gets installed here:
#   - k3s Kubernetes cluster validation
#   - cert-manager
#   - ingress-nginx
#   - Rancher
#   - ArgoCD
#   - Namespaces and local TLS secrets for GitOps-managed workloads
#
# Application and monitoring workloads are deployed by ArgoCD from:
#   ../LLM-PLATFORM-POC-ARGOCD
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

RANCHER_HOSTNAME="rancher.localhost"
RANCHER_PASSWORD="SuperAdmin@123"
ARGOCD_PASSWORD="$RANCHER_PASSWORD"   # shared admin password across consoles

# Helm chart versions — pinned for reproducibility. Bumping any of these without
# verifying upgrade compatibility (CRDs, breaking changes) will break setup.
CERT_MANAGER_VERSION="v1.20.2"
RANCHER_VERSION="2.14.1"
INGRESS_NGINX_VERSION="4.15.1"
ARGOCD_CHART_VERSION="7.8.27"   # argo-cd chart 7.8.27 ⇒ ArgoCD v2.14.10

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
#   GitOps workload Ingress manifests still set ingressClassName: nginx explicitly.
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
step "STEP 5: Prepare GitOps workload namespaces"
# ─────────────────────────────────────────────────────────────────────────────

for ns in ai-platform monitoring; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

if [ -f /vagrant/certs/local-cert.pem ] && [ -f /vagrant/certs/local-key.pem ]; then
  for ns in ai-platform monitoring; do
    kubectl create secret tls local-tls-cert \
      --cert=/vagrant/certs/local-cert.pem \
      --key=/vagrant/certs/local-key.pem \
      -n "$ns" --dry-run=client -o yaml | kubectl apply -f -
  done
  log "Local TLS secrets prepared for ArgoCD-managed workloads"
else
  warn "No local SSL certificates found for workload ingresses. ArgoCD-managed ingresses will need TLS secrets later."
fi

# ─────────────────────────────────────────────────────────────────────────────
step "STEP 6: Install ArgoCD"
# ─────────────────────────────────────────────────────────────────────────────

helm_repo_add_or_update argo https://argoproj.github.io/argo-helm
helm repo update argo

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Reuse the mkcert-issued local TLS cert if it's been generated (deploy.sh).
# Without it, the chart falls back to its own self-signed cert via tls: true.
if [ -f /vagrant/certs/local-cert.pem ] && [ -f /vagrant/certs/local-key.pem ]; then
  kubectl create secret tls local-tls-cert \
    --cert=/vagrant/certs/local-cert.pem \
    --key=/vagrant/certs/local-key.pem \
    -n argocd --dry-run=client -o yaml | kubectl apply -f -
fi

# Pin the admin password by passing a bcrypt hash to the chart. The Mtime field
# is what triggers ArgoCD to re-read the password on `helm upgrade` — bumping
# it on every run guarantees a password change actually takes effect. Setting
# argocdServerAdminPassword also suppresses creation of argocd-initial-admin-secret.
if ! command -v htpasswd >/dev/null; then
  log "Installing apache2-utils for bcrypt password hashing..."
  sudo apt-get update -qq && sudo apt-get install -y -qq apache2-utils
fi
ARGOCD_PASSWORD_BCRYPT=$(htpasswd -nbBC 10 "" "$ARGOCD_PASSWORD" | tr -d ':\n' | sed 's|^\$2y|\$2a|')
ARGOCD_PASSWORD_MTIME=$(date -u +%FT%TZ)

# Build values inline. server.insecure=true makes argocd-server speak plain
# HTTP to the ingress; nginx terminates TLS upstream. Skipping that flag forces
# HTTPS-on-HTTPS, which needs backend-protocol=HTTPS plus a self-signed cert
# nginx must trust — overkill for a single-cluster local setup.
ARGOCD_VALUES=/tmp/argocd-values.yaml
cat > "$ARGOCD_VALUES" <<EOF
global:
  domain: argocd.localhost

configs:
  params:
    server.insecure: true
  secret:
    argocdServerAdminPasswordMtime: "$ARGOCD_PASSWORD_MTIME"
EOF
# bcrypt hash contains literal $; write it via single-quoted YAML so the
# unquoted heredoc above doesn't try to expand $2a / $10 as shell vars.
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
  "ingress-nginx ingress-nginx" \
  "argocd argocd"; do
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
helm list -A --filter '^(cert-manager|rancher|ingress-nginx|argocd)$' || true
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
step "DONE — Infrastructure is ready"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}┌──────────────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}│  LLM Platform Infrastructure (HTTPS via mkcert)          │${NC}"
echo -e "${GREEN}├──────────────────────────────────────────────────────────┤${NC}"
echo -e "${GREEN}│  Rancher UI:    https://rancher.localhost:8443           │${NC}"
echo -e "${GREEN}│  ArgoCD UI:     https://argocd.localhost:8443            │${NC}"
echo -e "${GREEN}├──────────────────────────────────────────────────────────┤${NC}"
echo -e "${GREEN}│  Rancher password: $RANCHER_PASSWORD                     │${NC}"
echo -e "${GREEN}│  ArgoCD login:     admin / $ARGOCD_PASSWORD              │${NC}"
echo -e "${GREEN}└──────────────────────────────────────────────────────────┘${NC}"
echo ""
echo "Note: Vagrant forwards guest HTTPS 443 to host 8443."
echo "If domains do not resolve, add them to your host's /etc/hosts file:"
echo "127.0.0.1 rancher.localhost chat.localhost grafana.localhost prometheus.localhost argocd.localhost"
echo ""
echo "When setup.sh is invoked by Vagrant, the dev ArgoCD Application is applied next by the Vagrant trigger."
echo "If you ran setup.sh manually, apply it with:"
echo "  kubectl apply -f https://raw.githubusercontent.com/anasgrt/LLM-PLATFORM-POC-ARGOCD/main/argocd/app-dev.yaml"
echo ""
echo "After ArgoCD syncs, test with:"
echo "  curl -k -X POST https://chat.localhost:8443/api/analyze \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"question\": \"What errors are recurring in the logs?\"}'"
echo ""
echo "Monitor GitOps workloads after sync:"
echo "  kubectl get pods -n ai-platform -w"
echo "  kubectl get pods -n monitoring -w"
echo "  kubectl logs -n ai-platform deploy/qwen3-server -f"
echo "  kubectl top pods -n ai-platform"
