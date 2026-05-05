# Log Analysis Platform — POC

Fast RAG analyzes your log files immediately from retrieved Qdrant chunks. Qwen3 4B is still deployed and can be enabled with `USE_LLM=true`, but the default stays deterministic because CPU-only inference under VirtualBox is too slow for interactive use. The Vagrant build also deploys Prometheus and Grafana for Kubernetes, node, and workload monitoring.

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
│  │  │  │  │  namespace: monitoring              │  │  │  │  │
│  │  │  │  │  Prometheus + Grafana + exporters   │  │  │  │  │
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
1. Builds 4 container images on the host (Qwen3, embeddings, RAG app, ingestion)
2. Creates Control Plane VM with 4GB RAM, 2 CPU cores (Ubuntu 24.04)
3. Creates Data Plane VM with 20GB RAM, 4 CPU cores (Ubuntu 24.04)
4. Installs k3s server on control plane and joins the data plane worker
5. Imports prebuilt images into k3s containerd on both nodes
6. Installs Helm, cert-manager, ingress-nginx, and Rancher
7. Deploys Prometheus, Grafana, node-exporter, and kube-state-metrics
8. Deploys Qdrant, Qwen3 server, embedding server, RAG app to data plane
9. Downloads Qwen3 model from HuggingFace
10. Ingests sample log files into Qdrant

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
  - Data plane: k3s worker join, kubectl, prebuilt image import
- `setup.sh` — Deploys Helm charts and applies Kubernetes manifests
  - Monitoring is applied from `manifests/07-monitoring.yaml`

## Access

| What | URL | Accessible From |
|------|-----|----------------|
| Chat UI | http://localhost:30080 | Host machine |
| RAG API | http://localhost:30080/api/analyze | Host machine |
| Health check | http://localhost:30080/health | Host machine |
| Grafana | http://localhost:30300 | Host machine |
| Prometheus | http://localhost:30090 | Host machine |
| Chat UI HTTPS | https://localhost:30443 | Host machine (self-signed/default local cert warning expected) |
| Rancher UI | https://rancher.localhost:8443 | Host machine (forwarded through ingress-nginx on control plane) |

Rancher password: `SuperAdmin@123`
Grafana login: `admin` / `SuperAdmin@123`

**Note:** Traefik is disabled in k3s. ingress-nginx is the only ingress controller and serves both the application NodePorts and Rancher. Rancher intentionally uses `rancher.localhost` instead of bare `localhost` so it does not conflict with the application at `http://localhost:30080`.

Most systems resolve `*.localhost` to loopback. If yours does not, add `127.0.0.1 rancher.localhost` to the host machine's hosts file.

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

### Batch ingestion (static files)

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

### Live ingestion (running pods)

The platform includes a live log ingestion pipeline that streams logs from running pods into the RAG vector store in near real time. See [`LIVE-LOG-INGESTION.md`](LIVE-LOG-INGESTION.md) for full details.

```bash
# Verify the pipeline is healthy
kubectl get pods -n ai-platform -l app.kubernetes.io/name=fluent-bit

# Watch Fluent Bit shipping batches
kubectl logs -n ai-platform -l app.kubernetes.io/name=fluent-bit --tail=20

# Check Qdrant point count growing over time
kubectl exec -n ai-platform deploy/log-analysis-app -- \
  python3 -c 'import urllib.request,json; \
    print(json.loads(urllib.request.urlopen("http://qdrant:6333/collections/logs").read())["result"]["points_count"])'
```

## Monitor

```bash
# Pod status
kubectl get pods -n ai-platform
kubectl get pods -n monitoring

# Qwen3 logs (slow startup is normal — model loading takes 2-5 min)
kubectl logs -n ai-platform deploy/qwen3-server -f

# Resource usage
kubectl top pods -n ai-platform

# Prometheus targets
kubectl port-forward -n monitoring svc/prometheus 9090:9090

# Grafana dashboard
kubectl port-forward -n monitoring svc/grafana 3000:3000
```

Prometheus is also exposed from the host at `http://localhost:30090`, and Grafana is exposed at `http://localhost:30300`. Grafana is pre-provisioned with the Prometheus data source and an `LLM Platform Overview` dashboard.

## Troubleshooting

### Deployment Issues

| Problem | Cause | Fix |
|---------|-------|-----|
| `vagrant up control` hangs | Control plane VM resources | Check VirtualBox has 4GB RAM, 2 CPUs |
| `vagrant up data` hangs | Data plane VM resources | Check VirtualBox has 20GB RAM, 4 CPUs |
| `setup.sh failed` | Helm chart validation error | Check error logs, often annotation type mismatch |
| Rancher pod not starting | Certificate webhook issue | Check ingress annotations in setup.sh |
| Images not found | Build step failed | Run `docker images` inside data plane VM |
| Pod `ImagePullBackOff` | Wrong pull policy | Should be `Never` for local builds |
| k3s not ready | Provisioning timeout | SSH in: `vagrant ssh control && systemctl status k3s` |
| Data plane not joining cluster | Network connectivity | Check both VMs on same subnet (192.168.56.x) |
| Grafana or Prometheus not reachable | Monitoring NodePort not forwarded or pod not ready | Check `kubectl get pods -n monitoring` and Vagrantfile ports `30090`, `30300` |

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
| Rancher loads the app instead of Rancher | Wrong host header | Use `https://rancher.localhost:8443`, not `https://localhost:8443` |
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

`./teardown.sh` deletes Kubernetes resources. `vagrant destroy` removes the VMs, including VM-local monitoring data under `/var/lib/llm-platform/monitoring`.

## What this is / what this isn't

**Is:** A log analysis tool with both batch and live ingestion. You can feed it static log files via the ingestion job, or let the live pipeline stream logs from running pods in real time. Ask questions, get answers grounded in the most recent logs.

**Is:** A live log monitor. A Fluent Bit DaemonSet tails container logs from running pods, enriches them with Kubernetes metadata, and streams them into the RAG vector store every 5 seconds. The LLM can answer questions about logs that arrived seconds ago.

## Components

| Pod | Image | Port | Probe |
|-----|-------|------|-------|
| qwen3-server | llama-cpp-python 0.3.20 | 8080 | /v1/models |
| embedding-server | sentence-transformers 5.4.1 | 8080 | /health |
| qdrant | qdrant/qdrant:latest | 6333 | /healthz |
| log-analysis-app | FastAPI 0.136.0 | 8000 | /health |
| fluent-bit | fluent/fluent-bit:3.2 | 2020 | /api/v1/health |
| log-retention | curlimages/curl:latest | — | CronJob (daily at 02:00 UTC) |
| prometheus | prom/prometheus v2.55.1 | 9090 | /-/ready |
| grafana | grafana/grafana 11.4.0 | 3000 | /api/health |
| node-exporter | prometheus/node-exporter v1.8.2 | 9100 | /metrics |
| kube-state-metrics | kube-state-metrics v2.14.0 | 8080 | /metrics |

Total RAM: ~15-16 GB for AI workloads plus ~1 GB for monitoring on the data plane VM. The Vagrant build allocates 20 GB to the data plane and 4 GB to the control plane.
