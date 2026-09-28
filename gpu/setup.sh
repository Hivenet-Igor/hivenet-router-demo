#!/usr/bin/env bash
# Install what the GPU VM needs: Docker with the Compose plugin, the NVIDIA
# Container Toolkit (GPU access and telemetry for the containers), git, curl,
# Python pip. Installs only what is missing. Never reboots, never asks
# questions, never reinstalls an existing Docker. The one step that restarts
# Docker (registering the NVIDIA runtime) refuses to run while containers are
# up, unless you set FORCE=1. Safe to run twice.
set -euo pipefail
SUDO=sudo; [ "$(id -u)" = 0 ] && SUDO=
APT="$SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l apt-get -y -q"
fail() { echo "✗ $*" >&2; exit 1; }

echo "== NVIDIA driver"
command -v nvidia-smi >/dev/null && nvidia-smi -L | head -8 \
  || fail "No NVIDIA driver on this VM (nvidia-smi missing). Use a GPU image with the driver installed."

missing=()
for c in git curl; do command -v "$c" >/dev/null || missing+=("$c"); done
python3 -m pip --version >/dev/null 2>&1 || missing+=(python3-pip)
if [ ${#missing[@]} -gt 0 ]; then
  echo "== Installing ${missing[*]}"
  $APT update && $APT install "${missing[@]}"
fi

if ! command -v docker >/dev/null; then
  echo "== Installing Docker (with the Compose plugin)"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  $SUDO env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l sh /tmp/get-docker.sh
elif ! docker compose version >/dev/null 2>&1 && ! $SUDO docker compose version >/dev/null 2>&1; then
  echo "== Docker is here, adding the Compose plugin only (Docker keeps running)"
  if dpkg -s docker-ce >/dev/null 2>&1; then $APT install docker-compose-plugin
  else $APT update && $APT install docker-compose-v2; fi
fi

if ! $SUDO docker info 2>/dev/null | grep -qi 'runtimes:.*nvidia'; then
  running=$( ($SUDO docker ps -q 2>/dev/null || true) | wc -l)
  if [ "$running" -gt 0 ] && [ "${FORCE:-0}" != 1 ]; then
    fail "The NVIDIA runtime is missing, and registering it restarts Docker, which would stop the $running running container(s). Stop them first, or rerun with FORCE=1."
  fi
  echo "== Installing the NVIDIA Container Toolkit"
  if ! command -v nvidia-ctk >/dev/null; then
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | $SUDO gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | $SUDO tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
    $APT update && $APT install nvidia-container-toolkit
  fi
  $SUDO nvidia-ctk runtime configure --runtime=docker
  $SUDO systemctl restart docker
fi

if [ -n "$SUDO" ] && ! id -nG "$USER" | grep -qw docker; then
  $SUDO usermod -aG docker "$USER"
  NEWGRP=1
fi

echo
$SUDO docker --version
$SUDO docker compose version
$SUDO docker info 2>/dev/null | grep -i 'runtimes' || true
if [ "${NEWGRP:-0}" = 1 ]; then
  echo "Added $USER to the docker group. Run 'newgrp docker' (or log in again), then ./prepare.sh."
else
  echo "GPU VM ready. Next: ./prepare.sh"
fi
