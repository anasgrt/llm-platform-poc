/    # Build container images/,/echo "==> Container images built/c\
    # Import images from the pre-built directory mounted by Vagrant\
    echo "==> Importing pre-built images into k3s containerd (data plane)..."\
    \
    # Clean up disk space if necessary\
    echo "    Cleaning up disk space..."\
    df -h /\
\
    if [ -d /vagrant/prebuilt-images ]; then\
        for img in qwen3-server embedding-server rag-app ingestion; do\
            if [ -f "/vagrant/prebuilt-images/${img}.tar" ]; then\
                echo "    Importing ${img}:latest from tarball..."\
                sudo k3s ctr images import "/vagrant/prebuilt-images/${img}.tar"\
                echo "    ${img}:latest imported"\
            else\
                echo "    Warning: /vagrant/prebuilt-images/${img}.tar not found!"\
            fi\
        done\
    else\
        echo "    Warning: /vagrant/prebuilt-images/ directory not found! Did you run build-images-local.sh on the host?"\
    fi\
\
    # Verify images on data node\
    echo "==> Verifying images..."\
    echo "    Data plane images:"\
    sudo k3s ctr images ls | grep -E 'qwen3-server|embedding-server|rag-app|ingestion' | head -4\
\
    echo "==> Data plane provisioning complete!"\
    echo "==> Pre-built container images imported to data plane k3s"
