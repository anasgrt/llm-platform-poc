# LLM Platform POC Infrastructure

This repository owns the local infrastructure layer for the LLM platform POC.
It builds the Vagrant lab and installs the cluster management components:

- two Vagrant VMs on VirtualBox
- k3s control and data nodes
- cert-manager
- ingress-nginx
- Rancher
- ArgoCD
- local TLS secrets needed by the GitOps workloads

The Kubernetes workloads are now split into a separate folder/repository:

```txt
../LLM-PLATFORM-POC-ARGOCD
```

That ArgoCD repository owns the `ai-platform` and `monitoring` workloads:
Qdrant, Qwen3, embedding server, RAG app, Fluent Bit, log retention,
Prometheus, Grafana, node-exporter, kube-state-metrics, and sample-log
ingestion.

## Prerequisites

- macOS with Intel or Apple Silicon
- VirtualBox 7.0+
- Vagrant 2.3+
- Host machine with at least 24 GB RAM available
- `mkcert` recommended for trusted local certificates

## Start The Infrastructure

```bash
./deploy.sh
```

For a clean rebuild:

```bash
./deploy.sh --redeploy
```

You can also use Vagrant directly:

```bash
vagrant up
```

`vagrant up` provisions the VMs, runs `setup.sh` on the control node, and then
applies the dev ArgoCD `Application` from the GitOps repository on GitHub.
Workloads are deployed only through ArgoCD from `../LLM-PLATFORM-POC-ARGOCD`.

## What `setup.sh` Installs

`setup.sh` runs inside the control VM and installs:

- Helm
- cert-manager
- ingress-nginx as a DaemonSet with stable NodePorts
- Rancher
- workload namespaces and local TLS secrets
- ArgoCD

It intentionally does not apply `Deployment`, `DaemonSet`, `Job`, `CronJob`, or
monitoring manifests. Those live in the ArgoCD repository.

## Deploy The Workloads

The normal `vagrant up` flow creates the dev ArgoCD application automatically
after ArgoCD is installed by applying:

```bash
kubectl apply -f https://raw.githubusercontent.com/anasgrt/LLM-PLATFORM-POC-ARGOCD/main/argocd/app-dev.yaml
```

ArgoCD will sync `deploy/overlays/dev` from the GitOps repository.

## Access

Infrastructure URLs:

| What | URL |
|------|-----|
| Rancher | `https://rancher.localhost:8443` |
| ArgoCD | `https://argocd.localhost:8443` |

Default credentials:

| System | Login |
|--------|-------|
| Rancher | `admin` / `SuperAdmin@123` |
| ArgoCD | `admin` / `SuperAdmin@123` |

Workload URLs after ArgoCD sync:

| What | URL |
|------|-----|
| Chat UI | `https://chat.localhost:8443` |
| Grafana | `https://grafana.localhost:8443` |
| Prometheus | `https://prometheus.localhost:8443` |

If domains do not resolve, add this line to the host machine's hosts file:

```txt
127.0.0.1 rancher.localhost argocd.localhost chat.localhost grafana.localhost prometheus.localhost
```

## Model Storage

The ArgoCD workloads expect model files under `/vagrant/prebuilt-models` inside
the VMs. Use this repository to prepare them:

```bash
./download-models.sh
```

The synced Vagrant folder exposes `prebuilt-models/` to the cluster nodes.

## Operations

Check cluster nodes:

```bash
vagrant ssh control -c 'kubectl get nodes'
```

Check infrastructure pods:

```bash
vagrant ssh control -c 'kubectl get pods -A'
```

Clean up Kubernetes namespaces and Helm-installed components from inside the
control VM:

```bash
vagrant ssh control -c 'cd /vagrant && ./teardown.sh'
```

Destroy the VMs from the host:

```bash
vagrant destroy
```
