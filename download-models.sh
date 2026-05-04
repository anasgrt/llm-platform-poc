#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
LLM_REPO="Qwen/Qwen3-4B-GGUF"
LLM_FILE="Qwen3-4B-Q4_K_M.gguf"

mkdir -p prebuilt-models
echo "==> Setting up prebuilt models directly on host"

echo "==> Setting up temporary virtual environment..."
VENV_DIR=$(mktemp -d)
python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/pip" install -q huggingface_hub

# 1. Download Qwen (GGUF) using huggingface_hub
QWEN_MODEL_FILE="prebuilt-models/${LLM_FILE}"
if [ ! -f "$QWEN_MODEL_FILE" ] || [ ! -s "$QWEN_MODEL_FILE" ] || [ "$(stat -f%z "$QWEN_MODEL_FILE")" -lt 1000 ]; then
    echo "==> Downloading ${LLM_FILE}..."
    "$VENV_DIR/bin/python3" -c "
from huggingface_hub import hf_hub_download
import shutil
try:
    file_path = hf_hub_download(repo_id='${LLM_REPO}', filename='${LLM_FILE}')
    shutil.copy(file_path, '${QWEN_MODEL_FILE}')
except Exception as e:
    print(f'Failed to download via huggingface_hub: {e}')
"
else
    echo "==> [ok] Qwen model already exists and seems valid: $QWEN_MODEL_FILE"
fi

# 2. Download all-MiniLM-L6-v2 directly using huggingface_hub
echo "==> Downloading embedding model all-MiniLM-L6-v2..."
"$VENV_DIR/bin/python3" -c "
import os
from huggingface_hub import snapshot_download

local_dir = 'prebuilt-models/all-MiniLM-L6-v2'
os.makedirs(local_dir, exist_ok=True)
snapshot_download(
    repo_id='sentence-transformers/all-MiniLM-L6-v2',
    local_dir=local_dir,
    local_dir_use_symlinks=False
)
"

rm -rf "$VENV_DIR"

# Store the downloaded model filename in a config so the cluster setup scripts can read it dynamically if needed
echo "LLM_MASTER_FILE=$LLM_FILE" > prebuilt-models/model-config.env

echo "==> Models downloaded successfully. They will be shared via /vagrant/prebuilt-models."
