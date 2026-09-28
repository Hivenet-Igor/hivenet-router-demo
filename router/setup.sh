#!/usr/bin/env bash
# Install what the router VM needs: Docker with the Compose plugin, git, curl,
# openssl. Installs only what is missing. Never reboots, never restarts running
# services, never asks questions. Safe to run twice.
set -euo pipefail
SUDO=sudo; [ "$(id -u)" = 0 ] && SUDO=
APT="$SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -y -q"

missing=()
for c in git curl openssl; do command -v "$c" >/dev/null || missing+=("$c"); done
if [ ${#missing[@]} -gt 0 ]; then
  echo "== Installing ${missing[*]}"
  $APT update && $APT install "${missing[@]}"
fi

if ! command -v docker >/dev/null; then
  echo "== Installing Docker (with the Compose plugin)"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l sh /tmp/get-docker.sh
elif ! docker compose version >/dev/null 2>&1; then
  echo "== Docker is here, adding the Compose plugin only"
  if dpkg -s docker-ce >/dev/null 2>&1; then $APT install docker-compose-plugin
  else $APT update && $APT install docker-compose-v2; fi
fi

if [ -n "$SUDO" ] && ! id -nG "$USER" | grep -qw docker; then
  $SUDO usermod -aG docker "$USER"
  NEWGRP=1
fi

echo
docker --version 2>/dev/null || $SUDO docker --version
docker compose version 2>/dev/null || $SUDO docker compose version
if [ "${NEWGRP:-0}" = 1 ]; then
  echo "Added $USER to the docker group. Run 'newgrp docker' (or log in again), then ./up.sh."
else
  echo "Router VM ready. Next: ./up.sh"
fi
