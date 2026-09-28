#!/usr/bin/env bash
# One-time preparation of the GPU VM: check the NVIDIA container runtime,
# download the two checkpoints (~45 GB), pull the images.
set -euo pipefail
cd "$(dirname "$0")"

echo "== GPUs visible inside a container (this is what the agents use for telemetry)"
if ! docker run --rm --runtime nvidia -e NVIDIA_VISIBLE_DEVICES=all \
     --entrypoint nvidia-smi ghcr.io/hivenetoss/hivenet-agent:v0.1.3 \
     --query-gpu=index,name,memory.total --format=csv; then
  echo "The NVIDIA container runtime is missing. Run ./install-nvidia-toolkit.sh, then retry." >&2
  exit 1
fi

echo "== Weights (public, no Hugging Face token needed)"
command -v hf >/dev/null || pip install -U "huggingface_hub[hf_transfer]"
export HF_HUB_ENABLE_HF_TRANSFER=1
hf download HivenetQuant/Qwen3.8-27B-NVFP4 --local-dir ~/models/Qwen3.8-27B-NVFP4
hf download HivenetQuant/Qwen3.6-35B-A3B-NVFP4 --local-dir ~/models/Qwen3.6-35B-A3B-NVFP4

echo "== Images"
docker pull vllm/vllm-openai:v0.26.0
docker pull vllm/vllm-openai:v0.25.1
docker pull ghcr.io/hivenetoss/hivenet-agent:v0.1.3

mkdir -p ids
echo "Ready. Start the models with: docker compose up -d vllm-27b vllm-35b"
