#!/usr/bin/env bash
# Start the two agent sidecars once the router is up and its GPU-VM block
# has been pasted into .env, then follow their logs (Ctrl-C stops following).
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "✗ .env is missing: paste the 'GPU VM' block printed by the router's up.sh." >&2; exit 1; }
set -a; . ./.env; set +a
: "${HIVENET_ROUTER_JWT_SECRET:?✗ .env has no HIVENET_ROUTER_JWT_SECRET: paste the GPU VM block again}"
: "${ROUTER_ADDR:?✗ .env has no ROUTER_ADDR: paste the GPU VM block again}"
echo "Router: $ROUTER_ADDR:${ROUTER_GRPC_PORT:-9001}"
timeout 5 bash -c "</dev/tcp/$ROUTER_ADDR/${ROUTER_GRPC_PORT:-9001}" 2>/dev/null \
  || { echo "✗ Cannot reach $ROUTER_ADDR:${ROUTER_GRPC_PORT:-9001}. Is the router up, and is that TCP port published?" >&2; exit 1; }
docker compose up -d agent-27b agent-35b
docker compose logs -f --tail 20 agent-27b agent-35b
