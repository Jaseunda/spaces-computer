#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME="${COMPUTER_IMAGE:-ghcr.io/jaseunda/spaces-computer:latest}"
CONTAINER_NAME="${COMPUTER_CONTAINER:-spaces-computer-standalone}"
CONTROL_PORT="${COMPUTER_CONTROL_PORT:-7070}"
NO_VNC_PORT="${COMPUTER_NO_VNC_PORT:-6080}"
TOKEN="${COMPUTER_CONTROL_TOKEN:-}"
DATA_DIR="${COMPUTER_DATA_DIR:-$HOME/.spaces/computer-home}"

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker is not installed or not in PATH" >&2
  exit 1
fi

mkdir -p "$DATA_DIR"

if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# Stop any container occupying the ports
for OCCUPIER in $(docker ps -q --filter "publish=${CONTROL_PORT}" --filter "publish=${NO_VNC_PORT}"); do
  docker rm -f "$OCCUPIER" >/dev/null 2>&1 || true
done
docker rm -f base-computer >/dev/null 2>&1 || true

# Generate a random token if not specified
if [ -z "${TOKEN}" ]; then
  TOKEN="$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 24 || echo "spaces-$(date +%s)")"
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
echo "control endpoint: http://127.0.0.1:${CONTROL_PORT}"
echo "screen endpoint:  http://127.0.0.1:${NO_VNC_PORT}/embed.html"
echo "token:            ${TOKEN}"

# If --tunnel flag is provided and cloudflared is installed, offer unified tunnel
if [ "${1:-}" = "--tunnel" ] || [ "${TUNNEL:-0}" = "1" ]; then
  if command -v cloudflared >/dev/null 2>&1; then
    echo ""
    echo "initiating secure tunnels..."
    cloudflared tunnel --url "http://127.0.0.1:${NO_VNC_PORT}" > /tmp/spaces-tunnel-screen.log 2>&1 &
    SCREEN_TUNNEL_PID=$!
    cloudflared tunnel --url "http://127.0.0.1:${CONTROL_PORT}" > /tmp/spaces-tunnel-control.log 2>&1 &
    CONTROL_TUNNEL_PID=$!
    
    for _ in $(seq 1 40); do
      SCREEN_URL=$(grep -o 'https://[-a-z0-9.]*\.trycloudflare\.com' /tmp/spaces-tunnel-screen.log | head -n 1 || true)
      CONTROL_URL=$(grep -o 'https://[-a-z0-9.]*\.trycloudflare\.com' /tmp/spaces-tunnel-control.log | head -n 1 || true)
      if [ -n "$SCREEN_URL" ] && [ -n "$CONTROL_URL" ]; then
        break
      fi
      sleep 0.5
    done

    JSON_PAYLOAD=$(python3 -c "import json, base64; print(base64.b64encode(json.dumps({'c': '$CONTROL_URL', 's': '$SCREEN_URL/embed.html', 't': '$TOKEN'}).encode()).decode())")
    CONNECT_URL="https://spaces.notapublicfigureanymore.com/?connect=${JSON_PAYLOAD}"

    echo ""
    echo "remote configuration:"
    echo "1-click connect url:  ${CONNECT_URL}"
    echo "quick-connect key:    ${JSON_PAYLOAD}"
    echo "bearer token:         ${TOKEN}"
    echo ""
    echo "tunnels active (press ctrl+c to terminate tunnels)"
    wait "$CONTROL_TUNNEL_PID" 2>/dev/null || true
  fi
fi
