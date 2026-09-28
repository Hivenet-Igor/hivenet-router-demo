#!/usr/bin/env bash
# One-time preparation of the GPU VM: check Docker, the NVIDIA container
# runtime, free GPUs and ports, then download the two checkpoints (~45 GB)
# and pull the images. Stops with a clear message at the first problem.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"
MODELS="$HOME/models"
fail() { echo "✗ $*" >&2; exit 1; }

echo "== Docker Compose"
docker compose version >/dev/null 2>&1 \
  || fail "docker compose is missing. Run ./setup.sh first."
docker compose version

echo "== GPUs visible inside a container (this is what the agents use for telemetry)"
docker run --rm --runtime nvidia -e NVIDIA_VISIBLE_DEVICES=all \
  --entrypoint nvidia-smi ghcr.io/hivenetoss/hivenet-agent:v0.1.3 \
  --query-gpu=index,name,memory.used,memory.total --format=csv \
  || fail "The NVIDIA container runtime is missing. Run ./setup.sh first."

echo "== GPUs 0-3 and ports 8001, 8002, 9100, 9101 must be free"
busy=$(nvidia-smi --query-gpu=index,memory.used --format=csv,noheader,nounits 2>/dev/null \
       | awk -F', ' '$1<4 && $2>1024 {printf "GPU%s(%s MiB) ", $1, $2}')
[ -z "$busy" ] || fail "GPUs already in use: $busy. Stop what runs there, or edit NVIDIA_VISIBLE_DEVICES in docker-compose.yml."
ports=$(ss -ltn | awk '{print $4}' | grep -E ':(8001|8002|9100|9101)$' || true)
[ -z "$ports" ] || fail "Ports already in use: $ports. Stop what listens there, or edit the ports in docker-compose.yml."
echo "free"

echo "== Weights (public, no Hugging Face token needed)"
mkdir -p "$MODELS"
for d in "$MODELS" "$MODELS"/*/; do
  [ -e "$d" ] || continue
  [ -w "$d" ] || fail "$d is not writable by $USER. Fix it with: sudo chown -R $USER:$USER $MODELS"
done
command -v hf >/dev/null || python3 -m pip install --user -q -U "huggingface_hub[hf_xet]" \
  || python3 -m pip install --user -q -U --break-system-packages "huggingface_hub[hf_xet]"
hf download HivenetQuant/Qwen3.8-27B-NVFP4 --local-dir "$MODELS/Qwen3.8-27B-NVFP4"
hf download HivenetQuant/Qwen3.6-35B-A3B-NVFP4 --local-dir "$MODELS/Qwen3.6-35B-A3B-NVFP4"

echo "== Images"
docker pull "vllm/vllm-openai:${VLLM_VERSION:-v0.30.0}"

mkdir -p ids
echo "Ready. Start the models with: docker compose up -d vllm-27b vllm-35b"
