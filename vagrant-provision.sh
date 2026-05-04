#!/bin/bash
set -euo pipefail

# =============================================================================
# LLM Platform - Unified Vagrant Provisioning Script
# =============================================================================
# This script provisions both k3s control plane and data plane nodes
# Usage: ./vagrant-provision.sh [control|data]
# =============================================================================

# Validate arguments
if [ $# -ne 1 ]; then
    echo "Usage: $0 [control|data]"
    echo "  control - Provision k3s control plane node"
    echo "  data    - Provision k3s worker node and build container images"
    exit 1
fi

NODE_TYPE="$1"

if [[ "$NODE_TYPE" != "control" && "$NODE_TYPE" != "data" ]]; then
    echo "Error: Invalid node type '$NODE_TYPE'. Must be 'control' or 'data'."
    exit 1
fi

echo "==> Provisioning $NODE_TYPE plane VM..."

# =============================================================================
# Common Functions
# =============================================================================

expand_disk() {
    echo "==> Expanding disk to use full allocated space..."

    # Install growpart if not present
    if ! command -v growpart &> /dev/null; then
        apt-get update -qq || true
        apt-get install -y -qq cloud-guest-utils || true
    fi

    # Get the root partition device (e.g., /dev/sda1)
    ROOT_PART=$(findmnt -n -o SOURCE / || echo "/dev/root")
    ROOT_DEV=$(echo "$ROOT_PART" | sed 's/[0-9]*$//')
    ROOT_PART_NUM=$(echo "$ROOT_PART" | grep -oE '[0-9]+$' || echo "1")

    echo "    Root partition: $ROOT_PART on device $ROOT_DEV (partition $ROOT_PART_NUM)"

    # Check if using LVM
    if echo "$ROOT_PART" | grep -q "^/dev/mapper"; then
        echo "    LVM detected, expanding logical volume..."

        # Grow the partition table first
        growpart "$ROOT_DEV" "$ROOT_PART_NUM" 2>&1 || echo "    Partition already at max size"

        # Resize the physical volume
        if command -v pvresize &> /dev/null; then
            pvresize "$ROOT_DEV${ROOT_PART_NUM}" 2>&1 || echo "    pvresize skipped"
        fi

        # Extend the logical volume to use all free space
        if command -v lvextend &> /dev/null; then
            lvextend -l +100%FREE "$ROOT_PART" 2>&1 || echo "    lvextend skipped"
        fi

        # Resize the filesystem
        resize2fs "$ROOT_PART" 2>&1 || echo "    resize2fs failed, but continuing..."
        echo "    LVM filesystem expanded"
    else
        # Non-LVM: Expand the partition using growpart
        if growpart "$ROOT_DEV" "$ROOT_PART_NUM" 2>&1; then
            echo "    Partition expanded successfully"

            # Expand the filesystem
            if df -T | grep -qE '^/dev/root'; then
                # ext4 filesystem
                resize2fs "$ROOT_PART" 2>&1 || echo "    resize2fs failed, but continuing..."
            elif df -T | grep -qE '^/dev/mapper'; then
                # xfs filesystem
                if command -v xfs_growfs &> /dev/null; then
                    xfs_growfs / 2>&1 || echo "    xfs_growfs failed, but continuing..."
                fi
            fi
            echo "    Filesystem expanded"
        else
            echo "    Partition already at maximum size or growpart failed (this is OK)"
        fi
    fi

    # Show disk usage
    df -h /
}

configure_dns() {
    echo "==> Configuring DNS..."
    # Remove symlink to prevent overwriting systemd-resolved stub config
    rm -f /etc/resolv.conf
    cat > /etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
EOF

    echo "==> Configuring local hostnames..."
    if ! grep -q "192.168.56.10 llm-control" /etc/hosts; then
        echo "192.168.56.10 llm-control" >> /etc/hosts
    fi
    if ! grep -q "192.168.56.11 llm-data" /etc/hosts; then
        echo "192.168.56.11 llm-data" >> /etc/hosts
    fi
}

install_kubectl() {
    echo "==> Installing kubectl..."
    ARCH=$(uname -m)
    if [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        KUBECTL_ARCH="arm64"
    else
        KUBECTL_ARCH="amd64"
    fi
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${KUBECTL_ARCH}/kubectl"
    chmod +x kubectl
    mv kubectl /usr/local/bin/
}

setup_kubeconfig() {
    echo "==> Setting up kubeconfig..."
    mkdir -p /home/vagrant/.kube
    cp /etc/rancher/k3s/k3s.yaml /home/vagrant/.kube/config
    chown vagrant:vagrant /home/vagrant/.kube/config
    chmod 600 /home/vagrant/.kube/config

    mkdir -p /root/.kube
    cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
    chmod 600 /root/.kube/config

    chmod 644 /etc/rancher/k3s/k3s.yaml

    # Add kubectl alias 'k' for both vagrant and root users
    echo "==> Setting up kubectl alias..."

    # For vagrant user
    if ! grep -q "alias k=" /home/vagrant/.bashrc 2>/dev/null; then
        cat >> /home/vagrant/.bashrc << 'EOF'

# Kubernetes aliases
alias k=kubectl
complete -o default -F __start_kubectl k
EOF
    fi
    chown vagrant:vagrant /home/vagrant/.bashrc

    # For root user
    if ! grep -q "alias k=" /root/.bashrc 2>/dev/null; then
        cat >> /root/.bashrc << 'EOF'

# Kubernetes aliases
alias k=kubectl
complete -o default -F __start_kubectl k
EOF
    fi
}

setup_colored_prompt() {
    echo "==> Setting up colored bash prompt..."

    # Colorful prompt for vagrant user (green)
    cat > /home/vagrant/.bash_prompt << 'EOF'
# Colorful prompt for vagrant user
# Green username@hostname, blue working directory
PS1='\[\e[01;32m\]\u@\h\[\e[00m\]:\[\e[01;34m\]\w\[\e[00m\]\$ '

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm*|vte*)
    PS1='\[\e]0;\u@\h: \w\a\]\[\e[01;32m\]\u@\h\[\e[00m\]:\[\e[01;34m\]\w\[\e[00m\]\$ '
    ;;
*)
    ;;
esac
EOF
    chown vagrant:vagrant /home/vagrant/.bash_prompt
    chmod +x /home/vagrant/.bash_prompt

    # Source the prompt file in .bashrc if not already done
    if ! grep -q ".bash_prompt" /home/vagrant/.bashrc 2>/dev/null; then
        cat >> /home/vagrant/.bashrc << 'EOF'

# Load custom prompt
if [ -f ~/.bash_prompt ]; then
    . ~/.bash_prompt
fi
EOF
    fi
    chown vagrant:vagrant /home/vagrant/.bashrc

    # Colored prompt for root user (red to indicate privileged access)
    cat > /root/.bash_prompt << 'EOF'
# Colorful prompt for root user
# Red username@hostname, blue working directory
PS1='\[\e[01;31m\]\u@\h\[\e[00m\]:\[\e[01;34m\]\w\[\e[00m\]\$ '

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm*|vte*)
    PS1='\[\e]0;\u@\h: \w\a\]\[\e[01;31m\]\u@\h\[\e[00m\]:\[\e[01;34m\]\w\[\e[00m\]\$ '
    ;;
*)
    ;;
esac
EOF

    # Source the prompt file in .bashrc if not already done
    if ! grep -q ".bash_prompt" /root/.bashrc 2>/dev/null; then
        cat >> /root/.bashrc << 'EOF'

# Load custom prompt
if [ -f ~/.bash_prompt ]; then
    . ~/.bash_prompt
fi
EOF
    fi
}

# =============================================================================
# Control Plane Provisioning
# =============================================================================

provision_control() {
    # Expand disk to use full allocated space
    expand_disk

    # Configure DNS
    configure_dns

    # Install k3s as server (control plane)
    echo "==> Installing k3s server..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--cluster-init --tls-san 192.168.56.10 --node-ip 192.168.56.10 --advertise-address 192.168.56.10 --flannel-iface=eth1" sh -

    # Install kubectl
    install_kubectl

    # Wait for k3s to be ready
    echo "==> Waiting for k3s control plane..."
    sleep 15
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    kubectl wait --for=condition=Ready nodes --all --timeout=120s

    # Set up kubeconfig and kubectl alias
    setup_kubeconfig

    # Set up colored prompt
    setup_colored_prompt

    # Get node token for worker join
    echo "==> Preparing for worker node join..."
    NODE_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
    SERVER_URL="https://192.168.56.10:6443"

    # Store join information for data plane
    echo "K3S_TOKEN=$NODE_TOKEN" > /vagrant/join-info.sh
    echo "K3S_URL=$SERVER_URL" >> /vagrant/join-info.sh
    chmod +x /vagrant/join-info.sh

    # Import images natively from Vagrant sync
    echo "==> Importing pre-built images into k3s containerd (control plane)..."
    if [ -d /vagrant/prebuilt-images ]; then
        for img in qwen3-server embedding-server rag-app ingestion; do
            if [ -f "/vagrant/prebuilt-images/${img}.tar" ]; then
                echo "    Importing ${img}:latest..."
                sudo k3s ctr images import "/vagrant/prebuilt-images/${img}.tar"
            fi
        done
    fi

    echo "==> Control plane provisioning complete!"
    echo "==> Node token and server URL saved for worker join"
}

# =============================================================================
# Data Plane Provisioning
# =============================================================================

provision_data() {
    # Expand disk to use full allocated space
    expand_disk

    # Configure DNS
    configure_dns

    # Wait for control plane to be ready
    echo "==> Waiting for control plane to be ready..."
    until ping -c 1 192.168.56.10 >/dev/null 2>&1; do
        echo "Control plane not reachable, waiting..."
        sleep 5
    done

    # Get join information from control plane
    echo "==> Retrieving join information..."
    if [ ! -f /vagrant/join-info.sh ]; then
        echo "Error: Join information not found. Control plane may not be ready."
        exit 1
    fi

    source /vagrant/join-info.sh

    # Install k3s as worker (join existing cluster)
    echo "==> Joining k3s cluster as worker..."
    curl -sfL https://get.k3s.io | K3S_URL="$K3S_URL" K3S_TOKEN="$K3S_TOKEN" INSTALL_K3S_EXEC="--node-ip 192.168.56.11 --flannel-iface=eth1" sh -

    # Install kubectl (useful for local debugging)
    install_kubectl

    # Import images from the pre-built directory mounted by Vagrant
    echo "==> Importing pre-built images into k3s containerd (data plane)..."

    # Clean up disk space if necessary
    echo "    Cleaning up disk space..."
    df -h /

    if [ -d /vagrant/prebuilt-images ]; then
        for img in qwen3-server embedding-server rag-app ingestion; do
            if [ -f "/vagrant/prebuilt-images/${img}.tar" ]; then
                echo "    Importing ${img}:latest from tarball..."
                sudo k3s ctr images import "/vagrant/prebuilt-images/${img}.tar"
                echo "    ${img}:latest imported"
            else
                echo "    Warning: /vagrant/prebuilt-images/${img}.tar not found!"
            fi
        done
    else
        echo "    Warning: /vagrant/prebuilt-images/ directory not found! Did you run build-images-local.sh on the host?"
    fi

    # Verify images on data node
    echo "==> Verifying images..."
    echo "    Data plane images:"
    sudo k3s ctr images ls | grep -E 'qwen3-server|embedding-server|rag-app|ingestion' | head -4

    echo "==> Data plane provisioning complete!"
    echo "==> Pre-built container images imported to data plane k3s"
}

# =============================================================================
# Main Execution
# =============================================================================

case "$NODE_TYPE" in
    control)
        provision_control
        ;;
    data)
        provision_data
        ;;
esac
