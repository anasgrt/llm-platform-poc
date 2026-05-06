# -*- mode: ruby -*-
# vi: set ft=ruby :

# Multi-VM configuration for better resource isolation
# Control plane: k3s management (4GB RAM, 2 CPU)
# Data plane: worker capacity for ArgoCD-managed workloads (20GB RAM, 4 CPU)

Vagrant.configure("2") do |config|
  # Ubuntu 24.04 base box
  config.vm.box = "bento/ubuntu-24.04"
  config.vm.box_version = "202502.21.0"

  # Resize disks AFTER VM creation but BEFORE first boot (critical for VMDK format)
  # This ensures disks are resized before the VM starts, avoiding "locked media" errors
  config.trigger.before :up do |trigger|
    trigger.name = "Resize VM disks to allocated size"
    trigger.info = "Resizing control plane disk to 40GB and data plane disk to 60GB..."
    trigger.run = {
      path: "scripts/resize-disks.sh"
    }
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # VM 1: Control Plane (k3s server + management)
  # ─────────────────────────────────────────────────────────────────────────────
  config.vm.define "control" do |control|
    control.vm.hostname = "llm-control"

    control.vm.provider "virtualbox" do |vb|
      vb.name = "llm-platform-control"
      vb.memory = "4096"   # 4GB RAM for control plane
      vb.cpus = 2          # 2 CPU cores
      vb.customize ["modifyvm", :id, "--ioapic", "on"]
      vb.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
      vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    end

    # Private network for inter-VM communication
    control.vm.network "private_network", ip: "192.168.56.10"

    # Management ports through ingress-nginx NodePorts on the control node
    control.vm.network "forwarded_port", guest: 30080, host: 9080   # ingress-nginx HTTP
    control.vm.network "forwarded_port", guest: 30443, host: 8443   # ingress-nginx HTTPS

    # Control plane provisioning
    control.vm.provision "shell", path: "vagrant-provision.sh", args: ["control"]
  end

  # ─────────────────────────────────────────────────────────────────────────────
  # VM 2: Data Plane (ArgoCD-managed workloads)
  # ─────────────────────────────────────────────────────────────────────────────
  config.vm.define "data" do |data|
    data.vm.hostname = "llm-data"

    data.vm.provider "virtualbox" do |vb|
      vb.name = "llm-platform-data"
      vb.memory = "20480"  # 20GB RAM for workload capacity
      vb.cpus = 4          # 4 CPU cores
      vb.customize ["modifyvm", :id, "--ioapic", "on"]
      vb.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
      vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
    end

    # Private network - same subnet as control plane
    data.vm.network "private_network", ip: "192.168.56.11"

    # Application port forwarding
    data.vm.network "forwarded_port", guest: 30080, host: 30080  # ingress-nginx HTTP
    data.vm.network "forwarded_port", guest: 30443, host: 30443  # ingress-nginx HTTPS
    data.vm.network "forwarded_port", guest: 30090, host: 30090  # Prometheus NodePort
    data.vm.network "forwarded_port", guest: 30300, host: 30300  # Grafana NodePort

    # Data plane provisioning
    data.vm.provision "shell", path: "vagrant-provision.sh", args: ["data"]

    # Bootstrap platform components after the data plane is up. setup.sh installs
    # ArgoCD first; only then can the ArgoCD Application CRD accept app-dev.yaml.
    data.trigger.after :up do |trigger|
      trigger.name = "Bootstrap Platform"
      trigger.info = "Bootstrapping k3s, Rancher, ingress, ArgoCD, and the dev GitOps application..."
      trigger.run = {
        inline: <<~SHELL
          vagrant ssh control -c 'cd /vagrant && bash setup.sh && \
            kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=120s && \
            echo "Applying llm-platform-dev ArgoCD Application from GitHub..." && \
            kubectl apply -f https://raw.githubusercontent.com/anasgrt/LLM-PLATFORM-POC-ARGOCD/main/argocd/app-dev.yaml && \
            echo "ArgoCD Application submitted; workload sync continues in ArgoCD."'
        SHELL
      }
    end
  end
end
