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
# Normalize to avoid double slashes
VIEW_BASE="${VIEW_BASE%/}"

# Propose best URLs to try manually
RUN_URL="$VIEW_BASE/run?__report=version.rptdesign&__format=html"
FRAMESET_URL="$VIEW_BASE/frameset?__report=version.rptdesign&__format=html"
INDEX_URL="$VIEW_BASE/index.jsp?__report=version.rptdesign&__format=html"

# Programmatic sanity checks
TMP_DIR=$(mktemp -d)
HEADERS_FILE="$TMP_DIR/headers.txt"
BODY_FILE="$TMP_DIR/body.html"

expect_file="$REPO_ROOT/version.txt"
if [ -f "$expect_file" ]; then
  EXPECTED=$(head -n1 "$expect_file" | tr -d '\r' | sed -e 's/^\s\+//' -e 's/\s\+$//')
  if [ -n "$EXPECTED" ]; then
    echo "[run] Verifying version via: $RUN_URL"
    code=$(curl -sS -L -D "$HEADERS_FILE" -o "$BODY_FILE" --max-time 30 "$RUN_URL" -w "%{http_code}" || true)
    if [ "$code" = "200" ] && [ -s "$BODY_FILE" ] && grep -Fq -- "$EXPECTED" "$BODY_FILE"; then
      echo "[run] PASS version: found '$EXPECTED' in /run output"
    else
      echo "[run][WARN] Version check did not confirm '$EXPECTED' on /run (HTTP $code). Trying frameset..."
      code=$(curl -sS -L -D "$HEADERS_FILE" -o "$BODY_FILE" --max-time 30 "$FRAMESET_URL" -w "%{http_code}" || true)
      if [ "$code" = "200" ] && [ -s "$BODY_FILE" ] && grep -Fq -- "$EXPECTED" "$BODY_FILE"; then
        echo "[run] PASS version: found '$EXPECTED' in /frameset output"
      else
        echo "[run][WARN] Version not confirmed programmatically. Please open one of the URLs below to verify manually."
      fi
    fi
  fi
fi

# ODA XML quick test (optional)
ODA_XML_REPORT=${ODA_XML_REPORT:-oda_xml_test.rptdesign}
ODA_XML_DATA=${ODA_XML_DATA:-oda_xml_test.xml}
ODA_XML_EXPECTED=${ODA_XML_EXPECTED:-ODA_XML_OK}
ODA_XML_JAR_URL=${ODA_XML_JAR_URL:-https://download.eclipse.org/releases/2021-03/202103171000/plugins/org.eclipse.datatools.enablement.oda.xml_1.4.102.201901091730.jar}
BIRT_DIR=/opt/tomcat/webapps/birt
PLUGINS_DIR="$BIRT_DIR/WEB-INF/platform/plugins"
if [ -f "$REPO_ROOT/$ODA_XML_REPORT" ] && [ -f "$REPO_ROOT/$ODA_XML_DATA" ]; then
  echo "[run] Ensuring ODA XML test assets are in the container"
  docker cp "$REPO_ROOT/$ODA_XML_REPORT" "$CONTAINER_NAME:$BIRT_DIR/" >/dev/null
  docker cp "$REPO_ROOT/$ODA_XML_DATA" "$CONTAINER_NAME:$BIRT_DIR/" >/dev/null

  # Ensure XML ODA driver is available in platform/plugins (preferred)
  if docker exec "$CONTAINER_NAME" sh -lc "ls '$PLUGINS_DIR'/org.eclipse.datatools.enablement.oda.xml_*.jar >/dev/null 2>&1"; then
    echo "[run] XML ODA plugin jar present in platform/plugins"
  else
    if docker exec "$CONTAINER_NAME" sh -lc "ls '$BIRT_DIR'/WEB-INF/lib/org.eclipse.datatools.enablement.oda.xml_*.jar >/dev/null 2>&1"; then
      echo "[run] Copying XML ODA jar from WEB-INF/lib -> platform/plugins"
      docker exec "$CONTAINER_NAME" sh -lc "mkdir -p '$PLUGINS_DIR' && cp '$BIRT_DIR'/WEB-INF/lib/org.eclipse.datatools.enablement.oda.xml_*.jar '$PLUGINS_DIR'/"
      RESTART_NEEDED=1
    else
      echo "[run] Downloading XML ODA jar into platform/plugins"
      docker exec "$CONTAINER_NAME" sh -lc "mkdir -p '$PLUGINS_DIR'"
      curl -fL "$ODA_XML_JAR_URL" | docker exec -i "$CONTAINER_NAME" sh -lc "cat > '$PLUGINS_DIR'/org.eclipse.datatools.enablement.oda.xml.jar" || echo "[run][WARN] Download to container failed"
      RESTART_NEEDED=1
    fi
  fi

  if [ "${RESTART_NEEDED:-0}" = "1" ]; then
    echo "[run] Restarting container to load ODA plugin"
    docker restart "$CONTAINER_NAME" >/dev/null
    echo "[run] Waiting for Tomcat after restart"
    start_ts=$(date +%s)
    while :; do
      if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Server startup in"; then break; fi
      if [ $(( $(date +%s) - start_ts )) -ge $TIMEOUT_SEC ]; then err "Timed out waiting for Tomcat (post-restart)"; break; fi
      sleep 2
    done
  fi

  ODA_URL="$VIEW_BASE/run?__report=$ODA_XML_REPORT&__format=html"
  echo "[run] Verifying ODA XML via: $ODA_URL"
  code=$(curl -sS -L -D "$HEADERS_FILE" -o "$BODY_FILE" --max-time 30 "$ODA_URL" -w "%{http_code}" || true)
  if [ "$code" = "200" ] && [ -s "$BODY_FILE" ] && grep -Fq -- "$ODA_XML_EXPECTED" "$BODY_FILE"; then
    echo "[run] PASS ODA XML: found '$ODA_XML_EXPECTED' in ODA output"
  else
    echo "[run][WARN] ODA XML not confirmed programmatically (HTTP $code). Please open ODA URL manually."
    echo "[run][INFO] Recent container log tail:"
    docker logs --tail 120 "$CONTAINER_NAME" 2>&1 | sed 's/^/[docker] /'
  fi
else
  echo "[run][INFO] ODA XML test assets not present in repo; skipping ODA quick test."
fi

cat <<EOF

Container is running. Try opening these URLs in your browser:
- Version (preferred): $RUN_URL
- Version (frameset):  $FRAMESET_URL
- Version (index.jsp): $INDEX_URL
- ODA XML (if assets present): ${VIEW_BASE}/run?__report=${ODA_XML_REPORT}&__format=html

Press Ctrl+C to stop.

To stop the container manually:
  docker rm -f $CONTAINER_NAME
EOF

# Keep the script running to allow easy Ctrl+C
while docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; do sleep 60; done
