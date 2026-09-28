#!/usr/bin/env bash
# Start the two agent sidecars once the router is up and its GPU-VM block
# has been pasted into .env. Waits until both are registered, prints one line
# each. Full logs: docker compose logs -f agent-27b agent-35b
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "✗ .env is missing: paste the 'GPU VM' block printed by the router's up.sh." >&2; exit 1; }
set -a; . ./.env; set +a
: "${HIVENET_ROUTER_JWT_SECRET:?✗ .env has no HIVENET_ROUTER_JWT_SECRET: paste the GPU VM block again}"
: "${ROUTER_ADDR:?✗ .env has no ROUTER_ADDR: paste the GPU VM block again}"
echo "Router: $ROUTER_ADDR:${ROUTER_GRPC_PORT:-9001}"
timeout 5 bash -c "</dev/tcp/$ROUTER_ADDR/${ROUTER_GRPC_PORT:-9001}" 2>/dev/null \
  || { echo "✗ Cannot reach $ROUTER_ADDR:${ROUTER_GRPC_PORT:-9001}. Is the router up, and is that TCP port published?" >&2; exit 1; }
docker compose up -d --force-recreate agent-27b agent-35b >/dev/null 2>&1 \
  || docker compose up -d --force-recreate agent-27b agent-35b

for a in agent-27b agent-35b; do
  printf '%-10s ' "$a"
  for i in $(seq 1 180); do
    log=$(docker compose logs --no-log-prefix "$a" 2>/dev/null)
    if grep -q 'Registration successful' <<<"$log"; then
      model=$(sed -n 's/.*Model ready: \([^[:space:]]*\).*/\1/p' <<<"$log" | tail -1)
      gpu=$(grep -q 'NVML initialised' <<<"$log" && echo "GPU telemetry on" || echo "no GPU telemetry")
      echo "✓ registered · $model · $gpu"; continue 2
    fi
    [ "$i" = 15 ] && printf '(waiting, is vLLM still loading?) '
    sleep 2
  done
  echo "✗ not registered after 6 minutes. See: docker compose logs $a"
done
