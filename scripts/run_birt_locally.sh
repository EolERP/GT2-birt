#!/usr/bin/env bash
set -euo pipefail

# Simple helper to build and run the BIRT Docker image locally and print a URL to open
# It does NOT perform verification; it only starts the container and prints the best-guess viewer URL.

IMAGE_NAME=${IMAGE_NAME:-birt-local}
CONTAINER_NAME=${CONTAINER_NAME:-birt-local}
HOST_PORT=${HOST_PORT:-8080}
BASE_URL=${BASE_URL:-http://localhost:${HOST_PORT}}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log() { echo "[run] $*"; }
err() { echo "[run][ERROR] $*" >&2; }

if ! command -v docker >/dev/null 2>&1; then err "Docker is required"; exit 1; fi

# Stop and remove existing container if present
if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  log "Removing existing container $CONTAINER_NAME"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

log "Building image '$IMAGE_NAME'"
docker build -t "$IMAGE_NAME" "$REPO_ROOT"

log "Starting container '$CONTAINER_NAME' (port $HOST_PORT -> 8080)"
docker run -d --name "$CONTAINER_NAME" -p "$HOST_PORT:8080" "$IMAGE_NAME" >/dev/null

# Wait until Tomcat is ready
start_ts=$(date +%s)
TIMEOUT_SEC=${TIMEOUT_SEC:-120}
while :; do
  if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Server startup in"; then break; fi
  if [ $(( $(date +%s) - start_ts )) -ge $TIMEOUT_SEC ]; then err "Timed out waiting for Tomcat"; exit 1; fi
  sleep 2
done

# Detect likely viewer base
BASES=("$BASE_URL/birt" "$BASE_URL/viewer" "$BASE_URL/birt-viewer")
for b in "${BASES[@]}"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$b" || true)
  if [ "$code" = "200" ]; then VIEW_BASE="$b"; break; fi
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "$b/" || true)
  if [ "$code" = "200" ]; then VIEW_BASE="$b/"; break; fi
done
VIEW_BASE=${VIEW_BASE:-"$BASE_URL/birt"}

# Propose best URLs to try manually
RUN_URL="$VIEW_BASE/run?__report=version.rptdesign&__format=html"
FRAMESET_URL="$VIEW_BASE/frameset?__report=version.rptdesign&__format=html"
INDEX_URL="$VIEW_BASE/index.jsp?__report=version.rptdesign&__format=html"

cat <<EOF

Container is running. Try opening one of these URLs in your browser:
1) $RUN_URL
2) $FRAMESET_URL
3) $INDEX_URL

If the first one doesn't work, try the next ones. Press Ctrl+C to stop.

To stop the container:
  docker rm -f $CONTAINER_NAME
EOF

# Keep the script running to allow easy Ctrl+C
while docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; do sleep 60; done
