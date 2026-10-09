#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${COMPUTER_IMAGE:-ghcr.io/jaseunda/spaces-computer:latest}"
CONTAINER_NAME="${COMPUTER_CONTAINER:-spaces-computer-standalone}"
CONTROL_PORT="${COMPUTER_CONTROL_PORT:-7070}"
NO_VNC_PORT="${COMPUTER_NO_VNC_PORT:-6080}"
TOKEN="${COMPUTER_CONTROL_TOKEN:-spaces-secret-token}"
DATA_DIR="${COMPUTER_DATA_DIR:-$HOME/.spaces/computer-home}"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is not installed or not in PATH" >&2
  exit 1
fi

mkdir -p "$DATA_DIR"

if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

echo "pulling $IMAGE_NAME"
docker pull "$IMAGE_NAME" || true

echo "starting $CONTAINER_NAME"
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -p "127.0.0.1:${CONTROL_PORT}:7070" \
  -p "127.0.0.1:${NO_VNC_PORT}:6080" \
  --env DISPLAY=:1 \
  --env "COMPUTER_CONTROL_TOKEN=${TOKEN}" \
  --shm-size 512m \
  --cap-add SYS_ADMIN \
  --security-opt seccomp=unconfined \
  -v "${DATA_DIR}:/home/computer" \
  "$IMAGE_NAME" >/dev/null

echo "daemon running"
echo "control: http://127.0.0.1:${CONTROL_PORT}"
echo "screen:  http://127.0.0.1:${NO_VNC_PORT}/embed.html"
echo "token:   ${TOKEN}"
