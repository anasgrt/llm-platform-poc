#!/bin/bash
set -euo pipefail

echo "==> Building and packing Docker images on the host..."
mkdir -p prebuilt-images

# Determine architecture if necessary, but we'll default to the native docker build.
# If you are on an M-series Mac and VirtualBox is x86, you might need to add --platform linux/amd64
# to the docker build commands below.

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

    echo "    Building ${img}:latest..."
    docker build -t ${img}:latest "./images/${img}/"

    echo "    Saving ${img}:latest to tarball..."
    docker save -o "$tarball" ${img}:latest
done

echo "==> All images built and saved to prebuilt-images/. Ready for 'vagrant up'."
