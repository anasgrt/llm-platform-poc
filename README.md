# LLM Platform POC — Infrastructure

This repository provisions the local infrastructure for the LLM Platform proof of concept. It creates a two-node Kubernetes cluster on VirtualBox via Vagrant, installs the cluster management stack, and bootstraps the GitOps pipeline that drives all workload deployments.

## Architecture

The platform is split across two repositories with distinct responsibilities:

| Repository | Scope |
|---|---|
| **This repo (`llm-platform-poc`)** | VM lifecycle, k3s cluster, cert-manager, ingress-nginx, Rancher, ArgoCD, TLS secrets, workload namespaces |
| **[llm-platform-poc-argocd](https://github.com/anasgrt/llm-platform-poc-argocd)** | AI platform workloads (Qdrant, Qwen3, embedding server, RAG app, Fluent Bit, log retention, ingestion), monitoring stack (Prometheus, Grafana, node-exporter, kube-state-metrics), Kustomize overlays, GitHub Actions CI, ArgoCD Application manifests |

This repo does **not** deploy any application or monitoring workloads. Once ArgoCD is installed, the Vagrant bootstrap automatically applies the dev ArgoCD `Application` from the GitOps repository, which then syncs all workloads into the cluster.

## Infrastructure Layout

Two Vagrant VMs run on a private network (`192.168.56.0/24`):

| VM | Hostname | IP | Resources | Role |
|---|---|---|---|---|
| Control | `llm-control` | `192.168.56.10` | 4 GB RAM, 2 CPU, 40 GB disk | k3s server, Rancher, ArgoCD, cert-manager, ingress-nginx |
| Data | `llm-data` | `192.168.56.11` | 20 GB RAM, 4 CPU, 60 GB disk | k3s agent, runs all ArgoCD-managed workloads |

Both VMs use Ubuntu 24.04 LTS (`bento/ubuntu-24.04`).

## Prerequisites

- macOS (Intel or Apple Silicon)
- VirtualBox 7.0+
- Vagrant 2.3+
- Host machine with at least **24 GB RAM** available
- `mkcert` (recommended for browser-trusted local TLS certificates)

### Model Download

The AI workloads expect model files under `/vagrant/prebuilt-models` inside the VMs. Download them **before** the first deployment:

```bash
./download-models.sh
```

| Model | Size | Purpose |
|---|---|---|
| `Qwen3-4B-Q4_K_M.gguf` | ~2.5 GB | LLM inference (quantized GGUF) |
| `all-MiniLM-L6-v2/` | ~90 MB | Text embedding (384-dim) |

The Vagrant synced folder exposes `prebuilt-models/` to both VMs at `/vagrant/prebuilt-models`.

## Quick Start

```bash
./deploy.sh
```

This single command:

1. Generates local TLS certificates via `mkcert` for `*.localhost` domains
2. Provisions both VMs sequentially (`vagrant up control`, then `vagrant up data`)
3. Runs `setup.sh` on the control node to install the management stack
4. Applies the dev ArgoCD `Application` from the [GitOps repository](https://github.com/anasgrt/llm-platform-poc-argocd)
5. ArgoCD auto-syncs all workloads into `ai-platform` and `monitoring` namespaces

For a clean rebuild:

```bash
./deploy.sh --redeploy
```

## What Gets Installed

`setup.sh` runs inside the control VM and installs the following components in order:

| Step | Component | Version | Namespace |
|---|---|---|---|
| 0 | Preflight checks | — | — |
| 1 | k3s cluster validation | v1.35.4+k3s1 | — |
| 2 | Helm + Traefik removal | — | kube-system |
| 2 | cert-manager | v1.20.2 | cert-manager |
| 3 | ingress-nginx (DaemonSet) | 4.15.1 | ingress-nginx |
| 4 | Rancher | 2.14.1 | cattle-system |
| 5 | Workload namespaces + TLS secrets | — | ai-platform, monitoring |
| 6 | ArgoCD | chart 7.8.27 (v2.14.10) | argocd |

After setup completes, a Vagrant post-provision trigger applies the ArgoCD `Application` manifest:

```bash
kubectl apply -f https://raw.githubusercontent.com/anasgrt/LLM-PLATFORM-POC-ARGOCD/main/argocd/app-dev.yaml
```

This creates the `llm-platform-dev` Application, pointing ArgoCD at `deploy/overlays/dev` in the GitOps repository with automated sync and self-heal enabled.

## GitOps Workloads

Once ArgoCD syncs, the following workloads appear in the cluster — all managed by the [GitOps repository](https://github.com/anasgrt/llm-platform-poc-argocd):

### `ai-platform` Namespace

| Workload | Description |
|---|---|
| Qdrant | Vector database for log embeddings (cosine similarity) |
| Qwen3 LLM Server | Qwen3-4B model served via llama.cpp for inference |
| Embedding Server | sentence-transformers/all-MiniLM-L6-v2 (384-dim vectors) |
| RAG App | FastAPI application with Chat UI and `/api/analyze` endpoint |
| Ingestion Job | ArgoCD PostSync hook that loads sample logs into Qdrant |
| Fluent Bit | DaemonSet streaming live pod logs into the RAG pipeline |
| Log Retention | CronJob pruning vectors older than 7 days |

### `monitoring` Namespace

| Workload | Description |
|---|---|
| Prometheus | Metrics collection and alerting |
| Grafana | Dashboards and visualization |
| node-exporter | Host-level metrics |
| kube-state-metrics | Kubernetes object metrics |

## CI/CD & Environment Promotion

The GitOps repository defines two Kustomize overlays:

- **`dev`** — Auto-synced by ArgoCD on every GitHub Actions CI run
- **`prod`** — Manual sync; promote by copying known-good tags from `dev`

GitHub Actions builds four container images (`qwen3-server`, `embedding-server`, `rag-app`, `ingestion`), pushes them to GHCR, and bumps the image tags in the dev overlay automatically. ArgoCD detects the commit and reconciles the cluster within seconds.

## Access & Networking

### Service Endpoints

| Service | URL | Credentials | Available After |
|---|---|---|---|
| Rancher | `https://rancher.localhost:8443` | `admin` / `SuperAdmin@123` | `setup.sh` |
| ArgoCD | `https://argocd.localhost:8443` | `admin` / `SuperAdmin@123` | `setup.sh` |
| Chat UI | `https://chat.localhost:8443` | — | ArgoCD sync |
| Grafana | `https://grafana.localhost:8443` | `admin` / `SuperAdmin@123` | ArgoCD sync |
| Prometheus | `https://prometheus.localhost:8443` | — | ArgoCD sync |

If domains do not resolve, add this line to your host's `/etc/hosts`:

```
127.0.0.1 rancher.localhost argocd.localhost chat.localhost grafana.localhost prometheus.localhost
```

### Port Forwarding

Vagrant maps these guest NodePorts to host ports:

| Host Port | Guest NodePort | Service |
|---|---|---|
| 8443 | 30443 | ingress-nginx HTTPS (control node) |
| 9080 | 30080 | ingress-nginx HTTP (control node) |
| 30080 | 30080 | ingress-nginx HTTP (data node) |
| 30443 | 30443 | ingress-nginx HTTPS (data node) |
| 30090 | 30090 | Prometheus NodePort |
| 30300 | 30300 | Grafana NodePort |

## Operations

Check cluster status:

```bash
vagrant ssh control -c 'kubectl get nodes'
vagrant ssh control -c 'kubectl get pods -A'
```

Monitor ArgoCD-managed workloads:

```bash
vagrant ssh control -c 'kubectl get pods -n ai-platform'
vagrant ssh control -c 'kubectl get pods -n monitoring'
```

Tail application logs:

```bash
vagrant ssh control -c 'kubectl logs -n ai-platform deploy/log-analysis-app -f'
vagrant ssh control -c 'kubectl logs -n ai-platform deploy/qwen3-server -f'
```

Test the RAG API:

```bash
curl -k -X POST https://chat.localhost:8443/api/analyze \
  -H 'Content-Type: application/json' \
  -d '{"question": "What errors are recurring in the logs?"}'
```

Clean up Kubernetes resources without destroying VMs:

```bash
vagrant ssh control -c 'cd /vagrant && ./teardown.sh'
```

Manage VMs:

```bash
vagrant halt              # Stop both VMs
vagrant up                # Start both VMs
vagrant destroy           # Remove both VMs
```

## File Reference

```
.
├── Vagrantfile               # Two-VM definition (control + data)
├── deploy.sh                 # Host-side orchestrator (mkcert + vagrant up)
├── setup.sh                  # Control-node bootstrap (Helm, cert-manager, nginx, Rancher, ArgoCD)
├── vagrant-provision.sh      # Per-node provisioning (k3s server/agent, disk, DNS)
├── teardown.sh               # In-cluster cleanup (deletes all namespaces)
├── download-models.sh        # Downloads Qwen3 + MiniLM models from HuggingFace
├── join-info.sh              # Auto-generated k3s join token (shared via /vagrant)
├── certs/                    # mkcert-generated TLS certificates
├── prebuilt-models/          # Downloaded LLM + embedding model files
├── prebuilt-images/          # Pre-exported container image tarballs
└── scripts/
    └── resize-disks.sh       # VirtualBox disk resize (40 GB control, 60 GB data)
```
