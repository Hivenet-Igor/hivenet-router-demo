#!/usr/bin/env bash
# Start Ollama on the laptop GPU, pull a small model, then start its agent.
set -euo pipefail
cd "$(dirname "$0")"
MODEL="${OLLAMA_MODEL:-qwen3:1.7b}"

docker compose up -d ollama
until docker compose exec -T ollama ollama list >/dev/null 2>&1; do sleep 1; done
docker compose exec -T ollama ollama pull "$MODEL"
docker compose up -d agent
echo "Agent started. Follow it with: docker compose logs -f agent"
