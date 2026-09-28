#!/usr/bin/env bash
# Start the router, Prometheus and Grafana on this VM, then print what the
# GPU VM and the laptop need.
#
#   ./up.sh <address> [<https-url-of-port-8888>]
#
# <address> is the public IP (or DNS name) the agents use to reach this VM
# on TCP 9001 and 9000. Override the ports with ROUTER_GRPC_PORT and
# ROUTER_P2P_PORT. Secrets are created once in secrets/ and reused.
set -euo pipefail
cd "$(dirname "$0")"

ADDR="${1:?usage: ./up.sh <public IP or DNS name of this VM> [<https-url-of-port-8888>]}"
URL="${2:-https://<this-instance>-8888.<location>.tenants.hivecompute.ai}"
URL="${URL%/}"
GRPC_PORT="${ROUTER_GRPC_PORT:-9001}"
P2P_PORT="${ROUTER_P2P_PORT:-9000}"
if [[ "$ADDR" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then PROTO=ip4; else PROTO=dns4; fi

umask 077
mkdir -p secrets
if [ ! -f secrets/secrets.env ]; then
  cat > secrets/secrets.env <<EOF
JWT=$(openssl rand -hex 32)
ADMIN=$(openssl rand -hex 24)
GRAFANA=$(openssl rand -hex 12)
KEY=sk-hivenet-$(openssl rand -hex 24)
EOF
fi
# shellcheck disable=SC1091
. secrets/secrets.env
HASH=$(printf %s "$KEY" | sha256sum | cut -d' ' -f1)

cat > secrets/auth.yaml <<EOF
api:
  mode: api-key
  keys:
    - key_hash: "$HASH"
      key_preview: "sk-...${KEY: -4}"
      metadata: {name: "live demo", owner: "demo"}
      quota: {requests_per_minute: 600, tokens_per_day: 5000000}
admin:
  mode: api-key
EOF
printf 'HIVENET_ROUTER_JWT_SECRET=%s\nHIVENET_ROUTER_ADMIN_API_KEYS=%s\n' "$JWT" "$ADMIN" > secrets/router.env
cat > .env <<EOF
ROUTER_GRPC_PORT=$GRPC_PORT
ROUTER_P2P_PORT=$P2P_PORT
ROUTER_P2P_MADDR=/$PROTO/$ADDR/tcp/$P2P_PORT
GRAFANA_PASSWORD=$GRAFANA
EOF
chmod 644 secrets/auth.yaml

docker compose up -d
printf 'Waiting for the router'
for _ in $(seq 1 30); do
  curl -sf localhost:8888/health >/dev/null && break
  printf '.'; sleep 1
done
echo " up."

cat <<EOF

──────────────── paste on the GPU VM ────────────────
cat > ~/hivenet-router-demo/gpu/.env <<'X'
HIVENET_ROUTER_JWT_SECRET=$JWT
ROUTER_ADDR=$ADDR
ROUTER_GRPC_PORT=$GRPC_PORT
X

──────────────── paste on the laptop ────────────────
cat > ~/hivenet-demo.env <<'X'
export ROUTER=$URL
export KEY=$KEY
export ADMIN=$ADMIN
export HIVENET_ROUTER_JWT_SECRET=$JWT ROUTER_ADDR=$ADDR ROUTER_GRPC_PORT=$GRPC_PORT
X
. ~/hivenet-demo.env

Grafana: port 3000 · user admin · password $GRAFANA
EOF
