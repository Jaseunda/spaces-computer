#!/usr/bin/env bash
# spaces computer launcher
#
# Runs the published desktop image, which brings up Xvfb at its RANDR ceiling,
# x11vnc, websockify, the control server, picom and the agent theming itself.
#
# This used to apt-get a stock Debian and hand-start Xvfb + x11vnc + websockify,
# which never launched the control server: the terminal printed "container daemon
# online" while the advertised :7070 endpoint had nothing behind it, so a tunnel
# in front of it answered 502. The image is now the only supported path, and
# nothing is called online until the control server has actually answered.
set -euo pipefail

IMAGE_NAME="${COMPUTER_IMAGE:-ghcr.io/jaseunda/spaces-computer:latest}"
CONTAINER_NAME="${CONTAINER_NAME:-spaces-computer}"
CONTROL_PORT="${COMPUTER_CONTROL_PORT:-7070}"
NO_VNC_PORT="${COMPUTER_NO_VNC_PORT:-6080}"
TOKEN="${COMPUTER_CONTROL_TOKEN:-}"
ACCESS_MODE="${COMPUTER_ACCESS_MODE:-ask}"
DATA_DIR="${COMPUTER_DATA_DIR:-$HOME/.spaces/computer-home}"
APP_URL="${SPACES_APP_URL:-https://spaces.notapublicfigureanymore.com}"

RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; CYAN=$'\e[36m'; DIM=$'\e[2m'; BOLD=$'\e[1m'; RESET=$'\e[0m'

if ! command -v docker >/dev/null 2>&1; then
  printf "%s✗ docker not found in path%s\n" "$RED" "$RESET" >&2
  exit 1
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --tunnel) ACCESS_MODE="tunnel" ;;
    --local) ACCESS_MODE="local" ;;
    --image) shift; IMAGE_NAME="${1:-}" ;;
    *) printf "unknown option: %s\n" "$1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$ACCESS_MODE" = "ask" ]; then
  if [ -t 0 ]; then
    printf "\n%sspaces computer launcher%s\n\n" "$BOLD" "$RESET"
    printf "select access mode:\n  1) local only (127.0.0.1)\n  2) cloudflare tunnel (remote 1-click connect)\n\n"
    read -r -p "choice [1]: " REPLY || REPLY=""
    if [ "${REPLY:-1}" = "2" ]; then ACCESS_MODE="tunnel"; else ACCESS_MODE="local"; fi
  else
    ACCESS_MODE="local"
  fi
fi

# The key lives in the mounted home volume, not in the container: every run
# recreates the container, and a fresh key silently invalidates the connect link
# already pasted into the browser - which then reads as "shell is down, 401".
# `tr | head` trips pipefail: head closes the pipe and tr dies on SIGPIPE.
TOKEN_FILE="$DATA_DIR/.spaces/token"
if [ -z "$TOKEN" ] && [ -s "$TOKEN_FILE" ]; then
  TOKEN="$(tr -d '\n' < "$TOKEN_FILE")"
  printf ":: reusing the key from %s\n" "$TOKEN_FILE"
fi
if [ -z "$TOKEN" ]; then
  TOKEN="$(openssl rand -hex 12 2>/dev/null || printf 'spaces-%s' "$(date +%s)")"
  mkdir -p "$DATA_DIR/.spaces"
  printf '%s' "$TOKEN" > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE" 2>/dev/null || true
fi

if docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
  # Having the image is not having the current one: without this a user who ran
  # the launcher once kept their first build forever, however it changed.
  printf ":: updating %s\n" "$IMAGE_NAME"
  if docker pull "$IMAGE_NAME" >/dev/null 2>&1; then
    printf "   %s%s%s\n" "$DIM" "$(docker image inspect -f '{{.Id}}' "$IMAGE_NAME" | cut -c8-19)" "$RESET"
  else
    printf "%s! registry unreachable, continuing with the local copy%s\n" "$YELLOW" "$RESET" >&2
  fi
else
  printf ":: pulling %s\n" "$IMAGE_NAME"
  if ! docker pull "$IMAGE_NAME" >/dev/null 2>&1; then
    BUILD_DIR=""
    for candidate in "${COMPUTER_BUILD_DIR:-}" ./computer ../Base2/computer ../app/computer; do
      if [ -n "$candidate" ] && [ -f "$candidate/Dockerfile" ]; then BUILD_DIR="$candidate"; break; fi
    done
    if [ -z "$BUILD_DIR" ]; then
      printf "%s✗ no image %s and no computer/ directory to build one from%s\n" "$RED" "$IMAGE_NAME" "$RESET" >&2
      printf "  run (cd <spaces app> && npm run build:image) and tag it, or pass --image\n" >&2
      exit 1
    fi
    printf ":: building %s from %s\n" "$IMAGE_NAME" "$BUILD_DIR"
    docker build -t "$IMAGE_NAME" "$BUILD_DIR" >/dev/null
  fi
fi

# The compose stack uses its own container name on the same two ports; running
# both produces a networking error that says nothing about the real cause.
if { [ "$CONTROL_PORT" = "7070" ] || [ "$NO_VNC_PORT" = "6080" ]; } \
  && [ "$CONTAINER_NAME" != "spaces-computer-standalone" ] \
  && docker ps --format '{{.Names}}' | grep -qx 'spaces-computer-standalone'; then
  printf "%s✗ spaces-computer-standalone is already running on 7070 and 6080%s\n" "$RED" "$RESET" >&2
  printf "  docker compose down, or set CONTAINER_NAME and the COMPUTER_*_PORT overrides\n" >&2
  exit 1
fi

mkdir -p "$DATA_DIR"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

# The container runs UTC, so an agent asked for "today" writes yesterday's date
# through an evening. macOS keeps the zone behind /etc/localtime.
TIMEZONE="${COMPUTER_TZ:-$(basename "$(readlink /etc/localtime 2>/dev/null || echo UTC)")}"

printf ":: starting %s\n" "$CONTAINER_NAME"
docker run -d \
  --name "$CONTAINER_NAME" \
  --user 1000:1000 \
  --env "DISPLAY=:1" \
  --env "HOME=/home/computer" \
  --env "TZ=${TIMEZONE}" \
  --env "PATH=/home/computer/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  --env "COMPUTER_CONTROL_TOKEN=${TOKEN}" \
  -p "127.0.0.1:${CONTROL_PORT}:7070" \
  -p "127.0.0.1:${NO_VNC_PORT}:6080" \
  --memory 2g --memory-swap 2g --cpus 1.5 --shm-size 512m \
  --cap-add SYS_ADMIN --security-opt seccomp=unconfined \
  -v "${DATA_DIR}:/home/computer" \
  "$IMAGE_NAME" >/dev/null

# The control server binds before Xvfb, the theme and fluxbox are up, so a port
# that answers is not enough: wait for a window manager to own the root window
# and then probe the desktop endpoint.
printf ":: waiting for the desktop\n"
DEADLINE=$((SECONDS + 90))
until docker exec "$CONTAINER_NAME" env DISPLAY=:1 xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q '0x' \
  && curl -fsS --max-time 4 -X POST "http://127.0.0.1:${CONTROL_PORT}/v1/desktop" \
       -H "authorization: Bearer ${TOKEN}" -H 'content-type: application/json' \
       -d '{"display":":1","steps":[],"observe":false}' >/dev/null 2>&1; do
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || echo false)" != "true" ]; then
    printf "%s✗ the container exited%s\n" "$RED" "$RESET" >&2
    docker logs --tail 40 "$CONTAINER_NAME" >&2 || true
    exit 1
  fi
  if [ "$SECONDS" -gt "$DEADLINE" ]; then
    printf "%s✗ the control server never answered on %s%s\n" "$RED" "$CONTROL_PORT" "$RESET" >&2
    docker logs --tail 40 "$CONTAINER_NAME" >&2 || true
    exit 1
  fi
  sleep 1
done

printf "%s✓%s container daemon online\n\n" "$GREEN" "$RESET"
printf "%sconfiguration%s\n" "$BOLD" "$RESET"
printf "  control endpoint : %shttp://127.0.0.1:%s%s\n" "$CYAN" "$CONTROL_PORT" "$RESET"
printf "  screen endpoint  : %shttp://127.0.0.1:%s/embed.html%s\n" "$CYAN" "$NO_VNC_PORT" "$RESET"
printf "  bearer token     : %s%s%s\n\n" "$YELLOW" "$TOKEN" "$RESET"

if [ "$ACCESS_MODE" != "tunnel" ]; then
  printf "%slocal only%s: open the app on this machine and choose the local daemon.\n" "$DIM" "$RESET"
  printf "logs: docker logs -f %s\n" "$CONTAINER_NAME"
  exit 0
fi

if ! command -v cloudflared >/dev/null 2>&1; then
  printf "%s!%s cloudflared not installed, staying local only\n" "$YELLOW" "$RESET" >&2
  printf "  brew install cloudflared, then run this again with --tunnel\n" >&2
  exit 1
fi

printf ":: starting cloudflare tunnels\n"
# A shared log path is not safe: a cloudflared from an earlier run still holds
# its file descriptor open and keeps writing into the truncated file, so the
# first hostname in it can belong to a dead tunnel - or to the other port.
RUN_TAG="$$.$(date +%s)"
SCREEN_LOG="/tmp/spaces-tunnel-screen-${RUN_TAG}.log"
CONTROL_LOG="/tmp/spaces-tunnel-control-${RUN_TAG}.log"
cloudflared tunnel --url "http://127.0.0.1:${NO_VNC_PORT}" >"$SCREEN_LOG" 2>&1 &
SCREEN_PID=$!
cloudflared tunnel --url "http://127.0.0.1:${CONTROL_PORT}" >"$CONTROL_LOG" 2>&1 &
CONTROL_PID=$!
trap 'kill "$SCREEN_PID" "$CONTROL_PID" 2>/dev/null || true' EXIT

SCREEN_URL=""
CONTROL_URL=""
DEADLINE=$((SECONDS + 60))
while [ -z "$SCREEN_URL" ] || [ -z "$CONTROL_URL" ]; do
  SCREEN_URL="$(grep -o 'https://[-a-z0-9.]*\.trycloudflare\.com' "$SCREEN_LOG" | tail -n 1 || true)"
  CONTROL_URL="$(grep -o 'https://[-a-z0-9.]*\.trycloudflare\.com' "$CONTROL_LOG" | tail -n 1 || true)"
  if [ "$SECONDS" -gt "$DEADLINE" ]; then
    printf "%s✗ tunnels never published a URL%s\n" "$RED" "$RESET" >&2
    tail -20 "$CONTROL_LOG" >&2 || true
    exit 1
  fi
  sleep 1
done

# Hand over a key only once the daemon answers through the tunnel, so a 502 can
# never be reported as connected.
if ! curl -fsS --max-time 25 -X POST "${CONTROL_URL}/v1/desktop" \
    -H "authorization: Bearer ${TOKEN}" -H 'content-type: application/json' \
    -d '{"display":":1","steps":[],"observe":false}' >/dev/null; then
  printf "%s✗ the tunnel is up but the daemon is unreachable through it%s\n" "$RED" "$RESET" >&2
  printf "  %s answered %s\n" "$CONTROL_URL" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$CONTROL_URL/v1/desktop" || true)" >&2
  exit 1
fi

# Both halves are handed over as one credential, so verify the screen too rather
# than letting a link out with a control URL that answers on the noVNC port.
if ! curl -fsS --max-time 25 "${SCREEN_URL}/embed.html" >/dev/null; then
  printf "%s✗ the screen tunnel is up but noVNC did not answer at %s/embed.html%s\n" "$RED" "$SCREEN_URL" "$RESET" >&2
  exit 1
fi

# Ask the control server who it is before handing anything over. A link whose
# two halves were swapped looks exactly like a bad key to whoever pastes it, and
# the two need opposite fixes.
if [ "$CONTROL_URL" = "$SCREEN_URL" ]; then
  printf "%s✗ both tunnels published the same address, refusing to print a link%s\n" "$RED" "$RESET" >&2
  exit 1
fi
if ! curl -fsS --max-time 15 "$CONTROL_URL/health" | grep -q spaces-computer-control; then
  printf "%s✗ %s is not answering as the control server (it answered %s)%s\n" "$RED" "$CONTROL_URL" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$CONTROL_URL/health" || true)" "$RESET" >&2
  printf "  the screen tunnel answers the same way, so this link would only 401. Re-run this script.\n" >&2
  exit 1
fi

CONNECT_KEY="$(python3 -c 'import json, base64, sys; print(base64.b64encode(json.dumps({"c": sys.argv[1], "s": sys.argv[2], "t": sys.argv[3]}).encode()).decode())' "$CONTROL_URL" "${SCREEN_URL}/embed.html" "$TOKEN")"

printf "\n%s✓%s tunnels active\n\n" "$GREEN" "$RESET"
printf "%sremote connection%s\n" "$BOLD" "$RESET"
printf "  1-click url : %s%s/?connect=%s%s\n" "$GREEN" "$APP_URL" "$CONNECT_KEY" "$RESET"
printf "  connect key : %s%s%s\n\n" "$DIM" "$CONNECT_KEY" "$RESET"
printf "%skeep this terminal open: the tunnels and this key die with it%s\n" "$DIM" "$RESET"

wait
