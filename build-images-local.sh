#!/bin/bash
set -euo pipefail

echo "==> Building and packing Docker images on the host..."
mkdir -p prebuilt-images

# Detect the host arch so the produced images match the Vagrant VM's arch.
# VirtualBox is same-arch, so the data VM inherits the host's architecture.
case "$(uname -m)" in
    arm64|aarch64) PLATFORM="linux/arm64" ;;
    x86_64|amd64)  PLATFORM="linux/amd64" ;;
    *) echo "Unsupported host arch: $(uname -m)"; exit 1 ;;
esac
echo "    Target platform: ${PLATFORM}"

# Modern Docker Desktop defaults to buildx, which produces OCI multi-arch
# manifests with provenance attestations. k3s containerd's `ctr images import`
# fails on those with "no match for platform in manifest". The flags below
# force a single-platform Docker v2 manifest that imports cleanly:
#   --platform     pin to the host arch
#   --provenance=false    strip the SLSA attestations that confuse containerd
#   --output type=docker  emit the legacy single-image format (not OCI index)

for img in qwen3-server embedding-server rag-app ingestion; do
    tarball="prebuilt-images/${img}.tar"
    newer_file=""
    if [ -f "$tarball" ]; then
        newer_file="$(find "./images/${img}" -type f -newer "$tarball" -print -quit)"
    fi

    if [ -f "$tarball" ] && [ -z "$newer_file" ]; then
        echo "    Image ${img}:latest is current in prebuilt-images/, skipping build."
        continue
    fi

    echo "    Building ${img}:latest (${PLATFORM})..."
    docker buildx build \
        --platform "${PLATFORM}" \
        --provenance=false \
        --output type=docker \
        -t "${img}:latest" \
        "./images/${img}/"

    echo "    Saving ${img}:latest to tarball..."
    docker save -o "$tarball" "${img}:latest"
done

echo "==> All images built and saved to prebuilt-images/. Ready for 'vagrant up'."
