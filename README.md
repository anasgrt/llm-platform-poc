# Log Analysis Platform — POC

Fast RAG analyzes your log files immediately from retrieved Qdrant chunks. Qwen3 4B is still deployed and can be enabled with `USE_LLM=true`, but the default stays deterministic because CPU-only inference under VirtualBox is too slow for interactive use.

```txt
┌─────────────────────────────────────────────────────────────┐
│  Host Machine (macOS)                                       │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  VirtualBox + Vagrant                                 │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │  Control Plane VM (llm-control.local)           │  │  │
│  │  │  ┌───────────────────────────────────────────┐  │  │  │
│  │  │  │  k3s Control Plane                        │  │  │  │
│  │  │  │  ┌─────────────────────────────────────┐  │  │  │  │
│  │  │  │  │  Rancher UI                         │  │  │  │  │
│  │  │  │  │  Kubernetes API                     │  │  │  │  │
│  │  │  │  │  Cluster Management                 │  │  │  │  │
│  │  │  │  └─────────────────────────────────────┘  │  │  │  │
│  │  │  └───────────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  │  ┌─────────────────────────────────────────────────┐  │  │
│  │  │  Data Plane VM (llm-data.local)                 │  │  │
│  │  │  ┌───────────────────────────────────────────┐  │  │  │
│  │  │  │  k3s Worker Node                          │  │  │  │
│  │  │  │  ┌─────────────────────────────────────┐  │  │  │  │
│  │  │  │  │  namespace: ai-platform             │  │  │  │  │
│  │  │  │  │                                     │  │  │  │  │
│  │  │  │  │  ┌──────────┐  ┌────────┐  ┌──────┐ │  │  │  │  │
│  │  │  │  │  │Embed svc ├─→┤ Qdrant │  │ Qwen │ │  │  │  │  │
│  │  │  │  │  │MiniLM-L6 │  │Vectors │  │ 3.5  │ │  │  │  │  │
│  │  │  │  │  └────┬─────┘  └───┬────┘  └──┬───┘ │  │  │  │  │
│  │  │  │  │       └─────┬──────┘          │     │  │  │  │  │
│  │  │  │  │        ┌────┴────┐            │     │  │  │  │  │
│  │  │  │  │        │ RAG App ├────────────┘     │  │  │  │  │
│  │  │  │  │        │ FastAPI │                  │  │  │  │  │
│  │  │  │  │        └─────────┘                  │  │  │  │  │
│  │  │  │  └─────────────────────────────────────┘  │  │  │  │
│  │  │  └───────────────────────────────────────────┘  │  │  │
│  │  └─────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Prerequisites

- macOS with Intel or Apple Silicon (M1/M2/M3)
- VirtualBox 7.0+ — [Download](https://www.virtualbox.org/)
- Vagrant 2.3+ — `brew install --cask vagrant`
- Host machine: **24GB+ RAM available** (4GB for control plane + 20GB for data plane)

## Quick Start

### Option 1: Automatic Deployment (Recommended)

```bash
# Start the VMs and deploy everything automatically
./deploy.sh

# For a fresh start (destroys existing VMs first)
./deploy.sh --redeploy
```

This takes ~25-30 minutes on first run. Everything runs automatically:
1. Creates Control Plane VM with 4GB RAM, 2 CPU cores (Ubuntu 24.04)
2. Creates Data Plane VM with 20GB RAM, 6 CPU cores (Ubuntu 24.04)
3. Installs k3s server on control plane, kubectl for cluster management
4. Installs Docker on data plane for container image builds
5. Builds 4 container images locally (Qwen3, embeddings, RAG app, ingestion)
6. Deploys Qdrant, Qwen3 server, embedding server, RAG app to data plane
7. Downloads Qwen3 model from HuggingFace
8. Ingests sample log files into Qdrant
9. Installs Helm, NGINX Ingress, cert-manager, and Rancher

### Option 2: Manual Multi-VM Control

```bash
# Start both VMs
vagrant up

# Deploy platform manually from control plane
vagrant ssh control -c 'cd /vagrant && ./setup.sh'
```

### Deployment Architecture

**Scripts:**
- `deploy.sh` — Host-side orchestrator for multi-VM deployment
- `vagrant-provision.sh` — Unified provisioning script for both control and data planes
  - Usage: `./vagrant-provision.sh control` or `./vagrant-provision.sh data`
  - Control plane: k3s server, kubectl, kubeconfig setup
  - Data plane: Docker, container image builds, k3s worker join
- `setup.sh` — Deploys Helm charts, builds images, applies Kubernetes manifests

## Access

| What | URL | Accessible From |
|------|-----|----------------|
| Chat UI | http://localhost:30080 | Host machine |
| RAG API | http://localhost:30080/api/analyze | Host machine |
| Health check | http://localhost:30080/health | Host machine |
| Rancher UI | https://localhost:8443 | Host machine (forwarded from control plane) |

Rancher password: `SuperAdmin@123`

**Note:** The application runs on the data plane VM, but is accessible via port forwarding from the host. The control plane VM manages the Kubernetes cluster and provides the Rancher UI.

## Test it

```bash
# Via browser (from host)
open http://localhost:30080

# Via API (from host)
curl -s -X POST http://localhost:30080/api/analyze \
  -H 'Content-Type: application/json' \
  -d '{"question": "What caused the NFS outage?"}' | python3 -m json.tool

# From inside data plane VM
curl -s -X POST http://localhost:30080/api/analyze \
  -H 'Content-Type: application/json' \
  -d '{"question": "What caused the NFS outage?"}' | python3 -m json.tool

# From inside control plane VM (via kubectl port-forward)
kubectl port-forward -n ai-platform svc/log-analysis-app 8080:8000 &
curl -s -X POST http://localhost:8080/api/analyze \
  -H 'Content-Type: application/json' \
  -d '{"question": "What caused the NFS outage?"}' | python3 -m json.tool
```

## Ingest your own logs

```bash
# Drop your log files in
cp /path/to/your/*.log sample-logs/

# Reload and re-ingest
kubectl create configmap sample-logs \
  --from-file=sample-logs/ -n ai-platform \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl delete job log-ingestion -n ai-platform --ignore-not-found
kubectl apply -f manifests/05-ingestion-job.yaml

# Watch progress
kubectl logs -n ai-platform job/log-ingestion -f
```

## Monitor

```bash
# Pod status
kubectl get pods -n ai-platform

# Qwen3 logs (slow startup is normal — model loading takes 2-5 min)
kubectl logs -n ai-platform deploy/qwen3-server -f

# Resource usage
kubectl top pods -n ai-platform
```

## Troubleshooting

### Deployment Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| `vagrant up control` hangs | Control plane VM resources | Check VirtualBox has 4GB RAM, 2 CPUs |
| `vagrant up data` hangs | Data plane VM resources | Check VirtualBox has 20GB RAM, 6 CPUs |
| `setup.sh failed` | Helm chart validation error | Check error logs, often annotation type mismatch |
| Rancher pod not starting | Certificate webhook issue | Check ingress annotations in setup.sh |
| Images not found | Build step failed | Run `docker images` inside data plane VM |
| Pod `ImagePullBackOff` | Wrong pull policy | Should be `Never` for local builds |
| k3s not ready | Provisioning timeout | SSH in: `vagrant ssh control && systemctl status k3s` |
| Data plane not joining cluster | Network connectivity | Check both VMs on same subnet (192.168.56.x) |

### Runtime Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| Qwen3 pod stuck in `Init` | Model still downloading | `kubectl logs -n ai-platform deploy/qwen3-server -f` |
| Qwen3 pod `CrashLoopBackOff` | VM memory too low | Increase VM RAM to 20GB in Vagrantfile |
| Analysis request hangs | `USE_LLM=true` on CPU-only VirtualBox | Set `USE_LLM=false` in `manifests/04-rag-app.yaml` for Fast RAG |
| `ErrImageNeverPull` | Image pull policy set to Never | Images are built inside VM, no import needed |
| Embedding server OOMKilled | Memory limit too low | Check limits in manifests/03-embedding-server.yaml (needs 2Gi) |
| Qdrant pod restarting | Insufficient memory for indexes | Increase to 1Gi in manifests/01-qdrant.yaml |
| Ingestion job fails | Memory spike during embedding | Increase to 1Gi in manifests/05-ingestion-job.yaml |
| `localhost:30080` not working | Port forward not configured | Check Vagrantfile has port 30080 forwarded |
| Rancher UI certificate warning | Self-signed cert (expected) | Click through the browser warning |

### Manual Re-deployment

If deployment fails partway through:

```bash
# SSH into control plane VM
vagrant ssh control

# Clean up Kubernetes resources
./teardown.sh

# Re-run deployment
cd /vagrant && ./setup.sh
```

Or from host:
```bash
# Full redeploy (destroys both VMs)
./deploy.sh --redeploy
```

## Teardown

```bash
# From inside VM - clean up Kubernetes resources
./teardown.sh

# From host machine - destroy the entire VM
vagrant destroy
```

Deletes all Kubernetes resources and the VM. Nothing persists.

## What this is / what this isn't

**Is:** A batch log analysis tool. You feed it log files, ask questions, get answers grounded in those logs.

**Isn't:** A live log monitor. It doesn't stream logs from running pods. To analyze new logs, re-run ingestion.

## Components

| Pod | Image | Port | Probe |
|-----|-------|------|-------|
| qwen3-server | llama-cpp-python 0.3.20 | 8080 | /v1/models |
| embedding-server | sentence-transformers 5.4.1 | 8080 | /health |
| qdrant | qdrant/qdrant:latest | 6333 | /healthz |
| log-analysis-app | FastAPI 0.136.0 | 8000 | /health |

Total RAM: ~15-16 GB on data plane VM (20 GB allocated to data plane, 4 GB to control plane).
