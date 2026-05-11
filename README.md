# LLM Platform POC — Infrastructure

This repository provisions the local infrastructure for the LLM Platform proof of concept. It creates a two-node Kubernetes cluster on VirtualBox via Vagrant, installs ArgoCD, and bootstraps the App of Apps pipeline that cascade-installs the entire platform.

## Architecture

The platform is split across two repositories with distinct responsibilities:

| Repository | Scope |
|---|---|
| **This repo (`llm-platform-poc`)** | VM lifecycle, k3s cluster, namespaces, local TLS secrets, ArgoCD bootstrap |
| **[llm-platform-poc-argocd](https://github.com/anasgrt/llm-platform-poc-argocd)** | **Everything else via App of Apps**: cert-manager, ingress-nginx, Rancher, AI platform workloads, monitoring stack, Kustomize overlays, GitHub Actions CI, ArgoCD Application manifests |

This repo does **not** deploy any application, monitoring, or infrastructure Helm charts beyond ArgoCD itself. Once ArgoCD is installed, the Vagrant bootstrap applies the root App of Apps `Application` from the GitOps repository, which then cascade-installs the entire stack via sync waves.

## Infrastructure Layout

Two Vagrant VMs run on a private network (`192.168.56.0/24`):

| VM | Hostname | IP | Resources | Role |
|---|---|---|---|---|
| Control | `llm-control` | `192.168.56.10` | 4 GB RAM, 2 CPU, 40 GB disk | k3s server, ArgoCD |
| Data | `llm-data` | `192.168.56.11` | 12 GB RAM, 4 CPU, 60 GB disk | k3s agent, runs all ArgoCD-managed workloads |

Both VMs use Ubuntu 24.04 LTS (`bento/ubuntu-24.04`).

## Prerequisites

- macOS (Intel or Apple Silicon)
- VirtualBox 7.0+
- Vagrant 2.3+
- Host machine with at least **16 GB RAM** available
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
3. Runs `setup.sh` on the control node to install ArgoCD (the only Helm chart this repo manages)
4. Applies the root App of Apps `Application` from the [GitOps repository](https://github.com/anasgrt/llm-platform-poc-argocd)
5. ArgoCD cascade-installs the full stack via sync waves

For a clean rebuild:

```bash
./deploy.sh --redeploy
```

## What Gets Installed

### Bootstrap layer (`setup.sh` — this repo)

`setup.sh` runs inside the control VM and handles the irreducible bootstrap:

| Step | Component | Namespace |
|---|---|---|
| 0 | Preflight checks (hostname, k3s, nodes) | — |
| 1 | Helm | — |
| 2 | Namespaces + local TLS secrets | cattle-system, ingress-nginx, cert-manager, argocd, ai-platform, monitoring |
| 3 | ArgoCD (chart 9.5.13 / v3.4.1) | argocd |
| 4 | Root App of Apps Application | argocd |
| 5 | Wait for Rancher readiness | cattle-system |
| 6 | Health check | argocd |

### ArgoCD-managed layer (sync waves — GitOps repo)

After the root Application is applied, ArgoCD installs everything else in order:

| Sync Wave | Component | Version | Namespace |
|---|---|---|---|
| 0 | cert-manager | v1.20.2 | cert-manager |
| 1 | ingress-nginx (DaemonSet) | 4.15.1 | ingress-nginx |
| 2 | Rancher | 2.14.1 | cattle-system |
| 3 | AI platform + monitoring workloads | — | ai-platform, monitoring |

## GitOps Workloads

Once ArgoCD completes all sync waves, the following workloads appear in the cluster — all managed by the [GitOps repository](https://github.com/anasgrt/llm-platform-poc-argocd):

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
| ArgoCD | `https://argocd.localhost:8443` | `admin` / `SuperAdmin@123` | `setup.sh` |
| Rancher | `https://rancher.localhost:8443` | `admin` / `SuperAdmin@123` | Sync wave 2 |
| Chat UI | `https://chat.localhost:8443` | — | Sync wave 3 |
| Grafana | `https://grafana.localhost:8443` | `admin` / `SuperAdmin@123` | Sync wave 3 |
| Prometheus | `https://prometheus.localhost:8443` | — | Sync wave 3 |

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

Monitor ArgoCD sync progress:

```bash
vagrant ssh control -c 'kubectl get applications -n argocd'
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
├── setup.sh                  # Control-node bootstrap (Helm, ArgoCD, root App of Apps)
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
