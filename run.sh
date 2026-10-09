#!/usr/bin/env bash
set -euo pipefail

# terminal styling
BOLD=$'\033[1m'
DIM=$'\033[2m'
GREEN=$'\033[32m'
CYAN=$'\033[36m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
RESET=$'\033[0m'

CONTAINER_NAME="${COMPUTER_CONTAINER:-spaces-computer-standalone}"
CONTROL_PORT="${COMPUTER_CONTROL_PORT:-7070}"
NO_VNC_PORT="${COMPUTER_NO_VNC_PORT:-6080}"
TOKEN="${COMPUTER_CONTROL_TOKEN:-}"
DATA_DIR="${COMPUTER_DATA_DIR:-$HOME/.spaces/computer-home}"
IMAGE_NAME="debian:bookworm-slim"

# verify docker presence
if ! command -v docker >/dev/null 2>&1; then
  printf "%s✗ docker not found in path%s\n" "$RED" "$RESET" >&2
  printf "install docker to continue\n" >&2
  exit 1
fi

# interactive mode selection
ACCESS_MODE=""
if [ -n "${1:-}" ]; then
  case "$1" in
    --tunnel) ACCESS_MODE="tunnel" ;;
    --local) ACCESS_MODE="local" ;;
  esac
fi

if [ -z "$ACCESS_MODE" ] && [ -t 0 ]; then
  printf "\n%sspaces computer launcher%s\n\n" "$BOLD" "$RESET"
  printf "select access mode:\n"
  printf "  %s1%s) local only (127.0.0.1)\n" "$CYAN" "$RESET"
  printf "  %s2%s) cloudflare tunnel (remote 1-click connect)\n\n" "$CYAN" "$RESET"
  read -r -p "choice [1-2] (default: 1): " USER_CHOICE
  case "$USER_CHOICE" in
    2) ACCESS_MODE="tunnel" ;;
    *) ACCESS_MODE="local" ;;
  esac
elif [ -z "$ACCESS_MODE" ]; then
  # non-interactive pipe default
  if [ "${TUNNEL:-0}" = "1" ]; then
    ACCESS_MODE="tunnel"
  else
    ACCESS_MODE="local"
  fi
fi

mkdir -p "$DATA_DIR"

# clear stale containers
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

for OCCUPIER in $(docker ps -q --filter "publish=${CONTROL_PORT}" --filter "publish=${NO_VNC_PORT}"); do
  docker rm -f "$OCCUPIER" >/dev/null 2>&1 || true
done
docker rm -f base-computer >/dev/null 2>&1 || true

# generate random token
if [ -z "${TOKEN}" ]; then
  TOKEN="$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 24 || echo "spaces-$(date +%s)")"
fi

printf ":: preparing stock linux container\n"
docker pull "$IMAGE_NAME" >/dev/null 2>&1

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
  "$IMAGE_NAME" sleep infinity >/dev/null

printf ":: installing desktop environment\n"
docker exec -i "$CONTAINER_NAME" bash << 'BOOTSTRAP' >/dev/null 2>&1
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  xvfb x11vnc fluxbox novnc websockify python3 procps curl ca-certificates xdotool wmctrl xterm
mkdir -p /home/computer /tmp/.X11-unix
Xvfb :1 -screen 0 1280x800x24 -ac +extension RANDR +render -noreset >/tmp/xvfb.log 2>&1 &
sleep 1
fluxbox >/tmp/fluxbox.log 2>&1 &
x11vnc -display :1 -forever -shared -nopw -listen 127.0.0.1 -rfbport 5900 >/tmp/x11vnc.log 2>&1 &
websockify --web /usr/share/novnc 6080 127.0.0.1:5900 >/tmp/novnc.log 2>&1 &
BOOTSTRAP

printf "%s✓%s container daemon online\n\n" "$GREEN" "$RESET"
printf "%sconfiguration%s\n" "$BOLD" "$RESET"
printf "  control endpoint : %shttp://127.0.0.1:%s%s\n" "$CYAN" "$CONTROL_PORT" "$RESET"
printf "  screen endpoint  : %shttp://127.0.0.1:%s/vnc.html%s\n" "$CYAN" "$NO_VNC_PORT" "$RESET"
printf "  bearer token     : %s%s%s\n\n" "$YELLOW" "$TOKEN" "$RESET"

# launch cloudflare tunnel if requested
if [ "$ACCESS_MODE" = "tunnel" ]; then
  if ! command -v cloudflared >/dev/null 2>&1; then
    printf "%s!%s cloudflared not installed, skipping tunnel\n" "$YELLOW" "$RESET"
    exit 0
  fi

  printf ":: starting cloudflare tunnels\n"
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

  JSON_PAYLOAD=$(python3 -c "import json, base64; print(base64.b64encode(json.dumps({'c': '$CONTROL_URL', 's': '$SCREEN_URL/vnc.html', 't': '$TOKEN'}).encode()).decode())")
  CONNECT_URL="https://spaces.notapublicfigureanymore.com/?connect=${JSON_PAYLOAD}"

  printf "%s✓%s tunnels active\n\n" "$GREEN" "$RESET"
  printf "%sremote connection%s\n" "$BOLD" "$RESET"
  printf "  1-click url : %s%s%s\n" "$GREEN" "$CONNECT_URL" "$RESET"
  printf "  connect key : %s%s%s\n\n" "$DIM" "$JSON_PAYLOAD" "$RESET"
  printf "%spress ctrl+c to exit%s\n" "$DIM" "$RESET"
  wait "$CONTROL_TUNNEL_PID" 2>/dev/null || true
fi
