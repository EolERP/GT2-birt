#!/usr/bin/env bash
set -euo pipefail

# Configurable via ENV with sane defaults
IMAGE_NAME=${IMAGE_NAME:-birt-e2e}
CONTAINER_NAME=${CONTAINER_NAME:-birt-e2e-test}
HOST_PORT=${HOST_PORT:-8080}
BASE_URL=${BASE_URL:-http://localhost:${HOST_PORT}}
TIMEOUT_SEC=${TIMEOUT_SEC:-240}

# Version check inputs (best-effort)
REPORT_FILE=${REPORT_FILE:-version.rptdesign}
EXPECTED_FILE=${EXPECTED_FILE:-version.txt}
FAST_CHECK_TIMEOUT_SEC=${FAST_CHECK_TIMEOUT_SEC:-30}

# Credix inputs (authoritative)
CREDIX_REPORT_NAME=${CREDIX_REPORT_NAME:-credix_repayment_schedule.rptdesign}
CREDIX_XML_FILE_URL=${CREDIX_XML_FILE_URL:-https://gist.githubusercontent.com/dpodhola-eolerp/16266ad29c3bc8309c6601e2c15ac3d8/raw/4612297f7613d063ce2d0cf64e2f554ef6b03d7b/data.xml}
CREDIX_EXPECT_1=${CREDIX_EXPECT_1:-E2E_TEST_CredixBankAccount_123}
CREDIX_EXPECT_2=${CREDIX_EXPECT_2:-E2E_TEST_SCONT_Value_123}
CREDIX_ENDPOINT_PATH=${CREDIX_ENDPOINT_PATH:-/birt/frameset}
CREDIX_FORMAT=${CREDIX_FORMAT:-pdf}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Temp files
TMP_DIR=${TMP_DIR:-"$(mktemp -d)"}
HEADERS_FILE="$TMP_DIR/headers.txt"
BODY_HTML="$TMP_DIR/body.html"
BODY_PDF="$TMP_DIR/body.pdf"
BODY_TXT="$TMP_DIR/body.txt"

FAILED=1

log() { echo "[verify] $*" >&2; }
warn() { echo "[verify][WARN] $*" >&2; }
err() { echo "[verify][ERROR] $*" >&2; }

cleanup() {
  local code=$?
  if [[ $FAILED -ne 0 ]]; then
    warn "Collecting diagnostics before cleanup..."
    if [[ -s "$HEADERS_FILE" ]]; then
      warn "Response headers (first 80 lines):"
      sed -n '1,80p' "$HEADERS_FILE" | sed 's/^/[headers] /' >&2
    fi
    if [[ -s "$BODY_HTML" ]]; then
      warn "Response body (first 2000 chars HTML):"
      head -c 2000 "$BODY_HTML" | sed 's/^/[body] /' >&2 || true
    elif [[ -s "$BODY_TXT" ]]; then
      warn "Response text (first 2000 chars):"
      head -c 2000 "$BODY_TXT" | sed 's/^/[text] /' >&2 || true
    fi
    if command -v docker >/dev/null 2>&1; then
      warn "Docker logs (last 200 lines):"
      docker logs --tail 200 "$CONTAINER_NAME" 2>&1 | sed 's/^/[docker] /' >&2 || true
    fi
  fi
  if command -v docker >/dev/null 2>&1; then
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR" || true
  exit $code
}
trap cleanup EXIT INT TERM

require() { command -v "$1" >/dev/null 2>&1 || { err "Required command '$1' not found in PATH"; exit 1; }; }
require docker
require curl

# Validate inputs exist in repo (they may still be copied into container later)
if [[ ! -f "$REPO_ROOT/$REPORT_FILE" ]]; then
  warn "Report file not found in repo: $REPO_ROOT/$REPORT_FILE (will still try container as-is)"
fi
if [[ ! -f "$REPO_ROOT/$EXPECTED_FILE" ]]; then
  warn "Expected value file not found in repo: $REPO_ROOT/$EXPECTED_FILE (fast-check will be skipped)"
fi

EXPECTED_VALUE=""
if [[ -f "$REPO_ROOT/$EXPECTED_FILE" ]]; then
  EXPECTED_VALUE=$(head -n1 "$REPO_ROOT/$EXPECTED_FILE" | tr -d '\r' | sed -e 's/^\s\+//' -e 's/\s\+$//')
  if [[ -n "$EXPECTED_VALUE" ]]; then
    log "Expected value (fast-check): '$EXPECTED_VALUE'"
  else
    warn "Expected value from $EXPECTED_FILE is empty; fast-check will be skipped"
  fi
else
  warn "Missing $EXPECTED_FILE; fast-check will be skipped"
fi

# Docker daemon check
if ! docker info >/dev/null 2>&1; then err "Docker daemon is not running."; exit 1; fi

# Idempotency: remove existing container
if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  log "Removing existing container $CONTAINER_NAME"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

# Build image
log "Building image '$IMAGE_NAME'"
docker build -t "$IMAGE_NAME" "$REPO_ROOT"

# Run container
log "Starting container '$CONTAINER_NAME' (port $HOST_PORT -> 8080)"
docker run -d --name "$CONTAINER_NAME" -p "$HOST_PORT:8080" "$IMAGE_NAME" >/dev/null

# Wait until ready (Tomcat started)
wait_ready() {
  local start_ts
  start_ts=$(date +%s)
  local deadline=$((start_ts + TIMEOUT_SEC))
  while (( $(date +%s) <= deadline )); do
    if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Server startup in"; then
      return 0
    fi
    sleep 2
  done
  return 1
}
log "Waiting for service readiness (timeout ${TIMEOUT_SEC}s)"
wait_ready || { err "Service did not become ready in ${TIMEOUT_SEC}s"; exit 1; }

# Check logs for fatal errors during startup
if docker logs "$CONTAINER_NAME" 2>&1 | grep -Eqi 'fatal|fatalerror'; then
  err "Detected fatal error in Tomcat logs during startup"
  docker logs "$CONTAINER_NAME" | sed 's/^/[docker] /' >&2 || true
  exit 1
fi

# Extra test: verify Secure attribute on session cookie behind reverse proxy
# (best-effort: should not fail the build, but should warn loudly)
COOKIE_HDRS="$TMP_DIR/cookie_headers.txt"
if curl -fsSLI -D "$COOKIE_HDRS" -H 'X-Forwarded-Proto: https' "$BASE_URL/birt/" -o /dev/null; then
  if grep -Eqi '^Set-Cookie:.*;[[:space:]]*Secure' "$COOKIE_HDRS"; then
    log "Secure attribute PRESENT on Set-Cookie when X-Forwarded-Proto=https"
  else
    warn "Secure attribute NOT present on Set-Cookie despite X-Forwarded-Proto=https"
    warn "Note: Consider setting scheme=\"https\", secure=\"true\", and proxyPort on the HTTP Connector in server.xml if application requires secure cookies."
  fi
else
  warn "Curl to /birt/ for cookie check failed"
fi

# Fixed location (no discovery)
BIRT_DIR="/opt/tomcat/webapps/birt"
log "BIRT webapp root: $BIRT_DIR"

# Copy assets to container if present in repo (best effort; no failures here)
if [[ -f "$REPO_ROOT/$REPORT_FILE" ]] && ! docker exec "$CONTAINER_NAME" test -f "$BIRT_DIR/$REPORT_FILE"; then
  log "Copying $REPORT_FILE -> $BIRT_DIR"
  docker cp "$REPO_ROOT/$REPORT_FILE" "$CONTAINER_NAME:$BIRT_DIR/" || true
fi
if [[ -f "$REPO_ROOT/$EXPECTED_FILE" ]] && ! docker exec "$CONTAINER_NAME" test -f "$BIRT_DIR/$EXPECTED_FILE"; then
  log "Copying $EXPECTED_FILE -> $BIRT_DIR"
  docker cp "$REPO_ROOT/$EXPECTED_FILE" "$CONTAINER_NAME:$BIRT_DIR/" || true
fi

fetch_html() {
  local url="$1"
  : > "$HEADERS_FILE"; : > "$BODY_HTML"
  local code
  code=$(curl -sS -L -D "$HEADERS_FILE" -o "$BODY_HTML" --max-time 90 "$url" -w "%{http_code}" || true)
  echo "$code"
}

# ==========================================================
# 1) FAST version check (BEST-EFFORT): /birt/run (HTML)
#    This MUST NOT fail the build. Ever.
# ==========================================================
if [[ -n "$EXPECTED_VALUE" ]]; then
  VERSION_URL_RUN="${BASE_URL}/birt/run?__report=${REPORT_FILE}&__format=html"
  log "Fast-check URL (version, best-effort): $VERSION_URL_RUN"

  version_check_with_retry() {
    local url="$1"
    local start_ts
    start_ts=$(date +%s)
    local deadline=$((start_ts + FAST_CHECK_TIMEOUT_SEC))

    while (( $(date +%s) <= deadline )); do
      local code
      code=$(fetch_html "$url")
      if [[ "$code" == "200" ]] && [[ -s "$BODY_HTML" ]] && grep -Fq -- "$EXPECTED_VALUE" "$BODY_HTML"; then
        return 0
      fi
      sleep 2
    done
    return 1
  }

  if version_check_with_retry "$VERSION_URL_RUN"; then
    log "Fast-check SUCCESS: Found expected value '$EXPECTED_VALUE' in /birt/run output."
  else
    warn "Fast-check SKIPPED/FAILED: Did not confirm '$EXPECTED_VALUE' via /birt/run within ${FAST_CHECK_TIMEOUT_SEC}s. Continuing because PDF check is authoritative."
  fi
else
  warn "Fast-check skipped (no EXPECTED_VALUE). Continuing because PDF check is authoritative."
fi

# ==========================================================
# 2) AUTHORITATIVE production-like check: Credix PDF via /birt/frameset
# ==========================================================
log "Credix config: REPORT=$CREDIX_REPORT_NAME XML=$CREDIX_XML_FILE_URL EXPECT_1=$CREDIX_EXPECT_1 EXPECT_2=$CREDIX_EXPECT_2 ENDPOINT=$CREDIX_ENDPOINT_PATH FORMAT=$CREDIX_FORMAT"

# Verify report exists in container (hard fail)
if ! docker exec "$CONTAINER_NAME" test -f "$BIRT_DIR/$CREDIX_REPORT_NAME"; then
  warn "Listing $BIRT_DIR contents:"
  docker exec "$CONTAINER_NAME" ls -la "$BIRT_DIR" || true
  err "Credix report not found in container: $BIRT_DIR/$CREDIX_REPORT_NAME"
  FAILED=1
  exit 1
fi

# URL-encode XML file URL only
credix_urlencode() {
  local s="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$s"
  elif command -v python >/dev/null 2>&1; then
    python - "$s" <<'PY'
import sys
try:
    from urllib.parse import quote
except Exception:
    from urllib import quote
print(quote(sys.argv[1], safe=''))
PY
  else
    local i out="" c
    for (( i=0; i<${#s}; i++ )); do
      c=${s:i:1}
      case "$c" in
        [a-zA-Z0-9._~-]) out+="$c";;
        *) printf -v hex '%%%02X' "'${c}"; out+="$hex";;
      esac
    done
    echo -n "$out"
  fi
}

ENC_XML="$(credix_urlencode "$CREDIX_XML_FILE_URL")"
CREDIX_URL="${BASE_URL}${CREDIX_ENDPOINT_PATH}?xml_file=${ENC_XML}&__format=${CREDIX_FORMAT}&__report=${CREDIX_REPORT_NAME}"
log "Credix request URL: $CREDIX_URL"

OUT_DIR="$REPO_ROOT/out"
mkdir -p "$OUT_DIR"

# Download PDF (hard fail)
if ! curl -fsSL -D "$OUT_DIR/credix_headers.txt" "$CREDIX_URL" -o "$OUT_DIR/credix_report.pdf"; then
  err "curl download failed for Credix report"
  FAILED=1
  exit 1
fi

# Verify PDF magic (hard fail)
if ! head -c 5 "$OUT_DIR/credix_report.pdf" | grep -q "%PDF-"; then
  head -c 2000 "$OUT_DIR/credix_report.pdf" > "$OUT_DIR/credix_body_preview.txt" 2>/dev/null || true
  err "Credix response is not a PDF"
  FAILED=1
  exit 1
fi

# Extract text (best-effort)
if command -v pdftotext >/dev/null 2>&1; then
  pdftotext -q "$OUT_DIR/credix_report.pdf" "$OUT_DIR/credix_report.txt" || true
else
  strings -a "$OUT_DIR/credix_report.pdf" > "$OUT_DIR/credix_report.txt" || true
fi

# Verify expected strings in PDF (hard fail)
if ! grep -Fq -- "$CREDIX_EXPECT_1" "$OUT_DIR/credix_report.txt"; then
  err "Expected string 1 not found in PDF: $CREDIX_EXPECT_1"
  FAILED=1
  exit 1
fi
if ! grep -Fq -- "$CREDIX_EXPECT_2" "$OUT_DIR/credix_report.txt"; then
  err "Expected string 2 not found in PDF: $CREDIX_EXPECT_2"
  FAILED=1
  exit 1
fi

log "SUCCESS: Credix PDF report contains expected strings."

FAILED=0
exit 0
