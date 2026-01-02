#!/usr/bin/env bash
set -euo pipefail

# Configurable via ENV with sane defaults
IMAGE_NAME=${IMAGE_NAME:-birt-e2e}
CONTAINER_NAME=${CONTAINER_NAME:-birt-e2e-test}
HOST_PORT=${HOST_PORT:-8080}
BASE_URL=${BASE_URL:-http://localhost:${HOST_PORT}}
REPORT_FILE=${REPORT_FILE:-version.rptdesign}
EXPECTED_FILE=${EXPECTED_FILE:-version.txt}
REPORT_FORMAT=${REPORT_FORMAT:-html}
TIMEOUT_SEC=${TIMEOUT_SEC:-120}
REPORT_PATH=${REPORT_PATH:-}
REPORT_DIR=${REPORT_DIR:-}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Temp files
TMP_DIR=${TMP_DIR:-"$(mktemp -d)"}
HEADERS_FILE="$TMP_DIR/headers.txt"
RESPONSE_HTML="$TMP_DIR/report_response.html"
RESPONSE_PDF="$TMP_DIR/report_response.pdf"
RESPONSE_TXT="$TMP_DIR/report_response.txt"

FAILED=1

log() { echo "[verify] $*"; }
warn() { echo "[verify][WARN] $*" >&2; }
err() { echo "[verify][ERROR] $*" >&2; }

cleanup() {
  local code=$?
  if [[ $FAILED -ne 0 ]]; then
    warn "Collecting diagnostics before cleanup..."
    if [[ -s "$HEADERS_FILE" ]]; then
      warn "Response headers (first 50 lines):"
      sed -n '1,50p' "$HEADERS_FILE" | sed 's/^/[headers] /' >&2
    fi
    if [[ -s "$RESPONSE_HTML" ]]; then
      warn "Response body (first 2000 chars from HTML):"
      head -c 2000 "$RESPONSE_HTML" | sed 's/^/[body] /' >&2 || true
    elif [[ -s "$RESPONSE_TXT" ]]; then
      warn "Response text (first 2000 chars):"
      head -c 2000 "$RESPONSE_TXT" | sed 's/^/[text] /' >&2 || true
    fi
    if command -v docker >/dev/null 2>&1; then
      warn "Docker logs (last 200 lines):"
      docker logs --tail 200 "$CONTAINER_NAME" 2>&1 | sed 's/^/[docker] /' >&2 || true
    fi
  fi
  # Always try to cleanup container
  if command -v docker >/dev/null 2>&1; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR" || true
  exit $code
}
trap cleanup EXIT INT TERM

require() {
  command -v "$1" >/dev/null 2>&1 || { err "Required command '$1' not found in PATH"; exit 1; }
}

require docker
require curl

# Ensure expected inputs exist
if [[ ! -f "$REPO_ROOT/$REPORT_FILE" ]]; then
  err "Report file not found: $REPO_ROOT/$REPORT_FILE"
  exit 1
fi
if [[ ! -f "$REPO_ROOT/$EXPECTED_FILE" ]]; then
  err "Expected value file not found: $REPO_ROOT/$EXPECTED_FILE"
  exit 1
fi

# Read expected value (trim whitespace)
EXPECTED_VALUE=$(head -n1 "$REPO_ROOT/$EXPECTED_FILE" | tr -d '\r' | sed -e 's/^\s\+//' -e 's/\s\+$//')
if [[ -z "$EXPECTED_VALUE" ]]; then
  err "Expected value from $EXPECTED_FILE is empty"
  exit 1
fi
log "Expected value: '$EXPECTED_VALUE'"

# Check docker daemon
if ! docker info >/dev/null 2>&1; then
  err "Docker daemon is not running. Please start Docker and retry."
  exit 1
fi

# Idempotency: remove existing container
if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  log "Removing existing container $CONTAINER_NAME"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# Build image
log "Building image '$IMAGE_NAME' from $REPO_ROOT/Dockerfile"
docker build -t "$IMAGE_NAME" "$REPO_ROOT"

# Run container
log "Starting container '$CONTAINER_NAME' (port $HOST_PORT -> 8080)"
docker run -d --name "$CONTAINER_NAME" -p "$HOST_PORT:8080" "$IMAGE_NAME" >/dev/null

# Verify reports exist in expected default dir; fallback to autodetect/copy if needed
DEFAULT_REPORT_DIR="/opt/tomcat/webapps/birt"
resolve_report_dir() {
  if [[ -n "$REPORT_DIR" ]]; then
    echo "$REPORT_DIR"
    return 0
  fi
  # First, trust the Dockerfile default
  if docker exec "$CONTAINER_NAME" test -f "$DEFAULT_REPORT_DIR/$REPORT_FILE" && \
     docker exec "$CONTAINER_NAME" test -f "$DEFAULT_REPORT_DIR/$EXPECTED_FILE"; then
    echo "$DEFAULT_REPORT_DIR"
    return 0
  fi
  # Autodetect by searching for known viewer roots or existing .rptdesign files
  local candidates
  candidates=$(docker exec "$CONTAINER_NAME" sh -lc 'set -e; \
    for d in /opt/tomcat/webapps /usr/local/tomcat/webapps /srv /var/lib /opt; do \
      if [ -d "$d" ]; then \
        find "$d" -maxdepth 4 -type f -name "*.rptdesign" 2>/dev/null; \
      fi; \
    done | sort -u | head -n 20') || true
  if [[ -n "$candidates" ]]; then
    local first
    first=$(echo "$candidates" | head -n1)
    local dir
    dir=$(dirname "$first")
    echo "$dir"
    return 0
  fi
  # As last resort, assume DEFAULT
  echo "$DEFAULT_REPORT_DIR"
}

REPORT_TARGET_DIR=$(resolve_report_dir)
log "Using report directory in container: $REPORT_TARGET_DIR"

# If files missing there, copy them in
if ! docker exec "$CONTAINER_NAME" test -f "$REPORT_TARGET_DIR/$REPORT_FILE"; then
  log "Copying $REPORT_FILE into container:$REPORT_TARGET_DIR"
  docker cp "$REPO_ROOT/$REPORT_FILE" "$CONTAINER_NAME:$REPORT_TARGET_DIR/"
fi
if ! docker exec "$CONTAINER_NAME" test -f "$REPORT_TARGET_DIR/$EXPECTED_FILE"; then
  log "Copying $EXPECTED_FILE into container:$REPORT_TARGET_DIR"
  docker cp "$REPO_ROOT/$EXPECTED_FILE" "$CONTAINER_NAME:$REPORT_TARGET_DIR/"
fi

# Wait until server is ready
wait_ready() {
  local start_ts=$(date +%s)
  local deadline=$((start_ts + TIMEOUT_SEC))
  local http_code="000"
  while :; do
    # Check TCP/HTTP availability
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "$BASE_URL") || true
    # Check server startup in logs
    if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Server startup in"; then
      log "Tomcat reported startup complete"
      return 0
    fi
    if [[ "$http_code" != "000" ]]; then
      log "HTTP endpoint reachable at $BASE_URL (code $http_code)"
      return 0
    fi
    if (( $(date +%s) > deadline )); then
      return 1
    fi
    sleep 2
  done
}

log "Waiting for service to become ready (timeout ${TIMEOUT_SEC}s)"
if ! wait_ready; then
  err "Service did not become ready within ${TIMEOUT_SEC}s"
  exit 1
fi

# Endpoint autodetection
obvious_error() {
  # Detect typical error signals in body or headers
  grep -qiE "Exception|Whitelabel|HTTP Status|Not Found|404|500|error\.html|Stacktrace|SEVERE|There was an error" "$1"
}

try_endpoint() {
  local path="$1" # e.g. /birt/run or full URL
  local url
  if [[ "$path" == http* ]]; then
    url="$path?__report=${REPORT_FILE}&__format=${REPORT_FORMAT}"
  else
    url="${BASE_URL}${path}?__report=${REPORT_FILE}&__format=${REPORT_FORMAT}"
  fi
  log "Trying: $url"
  : >"$HEADERS_FILE"; : >"$RESPONSE_HTML"; : >"$RESPONSE_PDF"; : >"$RESPONSE_TXT"
  local code
  # Choose output target by format for the probe (we only need to judge success, not parse content yet)
  if [[ "$REPORT_FORMAT" == "pdf" ]]; then
    code=$(curl -sS -L -D "$HEADERS_FILE" -o "$RESPONSE_PDF" --max-time 60 "$url" -w "%{http_code}" || true)
    local body_probe="$RESPONSE_PDF"
  else
    code=$(curl -sS -L -D "$HEADERS_FILE" -o "$RESPONSE_HTML" --max-time 60 "$url" -w "%{http_code}" || true)
    local body_probe="$RESPONSE_HTML"
  fi
  if [[ "$code" != "200" ]]; then
    warn "HTTP $code for $url"
    return 1
  fi
  if [[ ! -s "$body_probe" ]]; then
    warn "Empty body for $url"
    return 1
  fi
  if obvious_error "$body_probe" || obvious_error "$HEADERS_FILE"; then
    warn "Obvious error detected for $url"
    return 1
  fi
  echo "$url"
  return 0
}

select_endpoint() {
  if [[ -n "$REPORT_PATH" ]]; then
    local base="$REPORT_PATH"
    if try_endpoint "$base"; then return 0; else return 1; fi
  fi
  # Prefer run endpoints first for direct content
  local candidates=(
    "/birt/run"
    "/viewer/run"
    "/birt-viewer/run"
    "/birt/frameset"
    "/viewer/frameset"
    "/birt-viewer/frameset"
  )
  local chosen=""
  for p in "${candidates[@]}"; do
    if chosen=$(try_endpoint "$p"); then
      echo "$chosen"
      return 0
    fi
  done
  return 1
}

SELECTED_URL=$(select_endpoint) || {
  err "Failed to find a working report endpoint. Tried candidates under $BASE_URL"
  warn "Candidates tested: /birt/run, /viewer/run, /birt-viewer/run, /birt/frameset, /viewer/frameset, /birt-viewer/frameset"
  exit 1
}
log "Selected endpoint: $SELECTED_URL"

# For verification prefer 'run' variant to ensure body has report content
VERIFY_URL="$SELECTED_URL"
if [[ "$VERIFY_URL" == *"/frameset"* ]]; then
  VERIFY_URL=${VERIFY_URL/\/frameset/\/run}
  log "Using run variant for verification: $VERIFY_URL"
fi

# Fetch final report and verify content
HTTP_CODE=""
if [[ "$REPORT_FORMAT" == "pdf" ]]; then
  HTTP_CODE=$(curl -sS -L -D "$HEADERS_FILE" -o "$RESPONSE_PDF" --max-time 120 "$VERIFY_URL" -w "%{http_code}") || true
  # Extract text from PDF
  if command -v pdftotext >/dev/null 2>&1; then
    pdftotext -q "$RESPONSE_PDF" "$RESPONSE_TXT" || true
  elif command -v mutool >/dev/null 2>&1; then
    mutool convert -o "$RESPONSE_TXT" txt "$RESPONSE_PDF" >/dev/null 2>&1 || true
  else
    warn "pdftotext not found, falling back to strings() for PDF text extraction"
    strings "$RESPONSE_PDF" > "$RESPONSE_TXT" || true
  fi
  BODY_FILE="$RESPONSE_TXT"
else
  HTTP_CODE=$(curl -sS -L -D "$HEADERS_FILE" -o "$RESPONSE_HTML" --max-time 120 "$VERIFY_URL" -w "%{http_code}") || true
  BODY_FILE="$RESPONSE_HTML"
fi

if [[ "$HTTP_CODE" != "200" ]]; then
  err "Verification request failed with HTTP $HTTP_CODE"
  err "URL used: $VERIFY_URL"
  FAILED=1
  exit 1
fi

if [[ ! -s "$BODY_FILE" ]]; then
  err "Verification response body is empty"
  err "URL used: $VERIFY_URL"
  FAILED=1
  exit 1
fi

if obvious_error "$BODY_FILE" || obvious_error "$HEADERS_FILE"; then
  err "Obvious error detected in verification response"
  err "URL used: $VERIFY_URL"
  FAILED=1
  exit 1
fi

if ! grep -Fq -- "$EXPECTED_VALUE" "$BODY_FILE"; then
  err "Expected value NOT found in report output"
  err "Expected: $EXPECTED_VALUE"
  err "URL used: $VERIFY_URL"
  # Print a few useful headers
  warn "Relevant headers:"
  grep -Ei '^(HTTP/|Server:|Content-Type:|Location:)' "$HEADERS_FILE" | sed 's/^/[headers] /' >&2 || true
  FAILED=1
  exit 1
fi

log "Success: report contains expected value '$EXPECTED_VALUE'"
FAILED=0
exit 0
