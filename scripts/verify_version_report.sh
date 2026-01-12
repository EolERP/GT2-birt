#!/usr/bin/env bash
set -euo pipefail

IMAGE_NAME=${IMAGE_NAME:-birt-e2e}
CONTAINER_NAME=${CONTAINER_NAME:-birt-e2e-test}
HOST_PORT=${HOST_PORT:-8080}
BASE_URL=${BASE_URL:-http://localhost:${HOST_PORT}}
TIMEOUT_SEC=${TIMEOUT_SEC:-240}

REPORT_FILE=${REPORT_FILE:-version.rptdesign}
EXPECTED_FILE=${EXPECTED_FILE:-version.txt}
FAST_CHECK_TIMEOUT_SEC=${FAST_CHECK_TIMEOUT_SEC:-30}

CREDIX_REPORT_NAME=${CREDIX_REPORT_NAME:-credix_repayment_schedule.rptdesign}
CREDIX_XML_FILE_URL=${CREDIX_XML_FILE_URL:-https://gist.githubusercontent.com/dpodhola-eolerp/16266ad29c3bc8309c6601e2c15ac3d8/raw/4612297f7613d063ce2d0cf64e2f554ef6b03d7b/data.xml}
CREDIX_EXPECT_1=${CREDIX_EXPECT_1:-E2E_TEST_CredixBankAccount_123}
CREDIX_EXPECT_2=${CREDIX_EXPECT_2:-E2E_TEST_SCONT_Value_123}
CREDIX_EXPECT_CZ=${CREDIX_EXPECT_CZ:-Číslo}

CREDIX_ENDPOINT_PATH=${CREDIX_ENDPOINT_PATH:-/birt/frameset}
CREDIX_FORMAT=${CREDIX_FORMAT:-pdf}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP_DIR=${TMP_DIR:-"$(mktemp -d)"}
HEADERS_FILE="$TMP_DIR/headers.txt"
BODY_HTML="$TMP_DIR/body.html"

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

require() { command -v "$1" >/dev/null 2>&1 || { err "Required command '$1' not found"; exit 1; }; }
require docker
require curl

if ! docker info >/dev/null 2>&1; then err "Docker daemon is not running."; exit 1; fi

if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
  log "Removing existing container $CONTAINER_NAME"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
fi

log "Building image '$IMAGE_NAME'"
docker build -t "$IMAGE_NAME" "$REPO_ROOT"

log "Starting container '$CONTAINER_NAME' (port $HOST_PORT -> 8080)"
docker run -d --name "$CONTAINER_NAME" -p "$HOST_PORT:8080" "$IMAGE_NAME" >/dev/null

wait_ready() {
  local start_ts deadline
  start_ts=$(date +%s)
  deadline=$((start_ts + TIMEOUT_SEC))
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

# Best-effort cookie test
COOKIE_HDRS="$TMP_DIR/cookie_headers.txt"
if curl -fsSLI -D "$COOKIE_HDRS" -H 'X-Forwarded-Proto: https' "$BASE_URL/birt/" -o /dev/null; then
  if grep -Eqi '^Set-Cookie:.*;[[:space:]]*Secure' "$COOKIE_HDRS"; then
    log "Secure attribute PRESENT on Set-Cookie when X-Forwarded-Proto=https"
  else
    warn "Secure attribute NOT present on Set-Cookie despite X-Forwarded-Proto=https"
  fi
else
  warn "Curl to /birt/ for cookie check failed"
fi

BIRT_DIR="/opt/tomcat/webapps/birt"
log "BIRT webapp root: $BIRT_DIR"

fetch_html() {
  local url="$1"
  : > "$HEADERS_FILE"; : > "$BODY_HTML"
  local code
  code=$(curl -sS -L -D "$HEADERS_FILE" -o "$BODY_HTML" --max-time 90 "$url" -w "%{http_code}" || true)
  echo "$code"
}

# Fast-check (best-effort)
EXPECTED_VALUE=""
if [[ -f "$REPO_ROOT/$EXPECTED_FILE" ]]; then
  EXPECTED_VALUE=$(head -n1 "$REPO_ROOT/$EXPECTED_FILE" | tr -d '\r' | sed -e 's/^\s\+//' -e 's/\s\+$//')
fi

if [[ -n "$EXPECTED_VALUE" ]]; then
  VERSION_URL_RUN="${BASE_URL}/birt/run?__report=${REPORT_FILE}&__format=html"
  log "Fast-check URL (version, best-effort): $VERSION_URL_RUN"

  start_ts=$(date +%s)
  deadline=$((start_ts + FAST_CHECK_TIMEOUT_SEC))
  ok=0
  while (( $(date +%s) <= deadline )); do
    code=$(fetch_html "$VERSION_URL_RUN")
    if [[ "$code" == "200" ]] && [[ -s "$BODY_HTML" ]] && grep -Fq -- "$EXPECTED_VALUE" "$BODY_HTML"; then
      ok=1; break
    fi
    sleep 2
  done

  if [[ "$ok" == "1" ]]; then
    log "Fast-check SUCCESS: Found expected value '$EXPECTED_VALUE'."
  else
    warn "Fast-check SKIPPED/FAILED: Did not confirm '$EXPECTED_VALUE' within ${FAST_CHECK_TIMEOUT_SEC}s."
  fi
else
  warn "Fast-check skipped (missing/empty EXPECTED_VALUE)."
fi

# Authoritative PDF check
log "Credix config: REPORT=$CREDIX_REPORT_NAME XML=$CREDIX_XML_FILE_URL EXPECT_1=$CREDIX_EXPECT_1 EXPECT_2=$CREDIX_EXPECT_2 EXPECT_CZ=$CREDIX_EXPECT_CZ"

if ! docker exec "$CONTAINER_NAME" test -f "$BIRT_DIR/$CREDIX_REPORT_NAME"; then
  warn "Listing $BIRT_DIR contents:"
  docker exec "$CONTAINER_NAME" ls -la "$BIRT_DIR" || true
  err "Credix report not found in container: $BIRT_DIR/$CREDIX_REPORT_NAME"
  FAILED=1
  exit 1
fi

credix_urlencode() {
  local s="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$s"
  else
    # fallback minimal encoder
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

PDF_FILE="$OUT_DIR/credix_report.pdf"
TXT_FILE="$OUT_DIR/credix_report.txt"
FONTS_FILE="$OUT_DIR/credix_fonts.txt"

if ! curl -fsSL -D "$OUT_DIR/credix_headers.txt" "$CREDIX_URL" -o "$PDF_FILE"; then
  err "curl download failed for Credix report"
  FAILED=1
  exit 1
fi

if ! head -c 5 "$PDF_FILE" | grep -q "%PDF-"; then
  head -c 2000 "$PDF_FILE" > "$OUT_DIR/credix_body_preview.txt" 2>/dev/null || true
  err "Credix response is not a PDF"
  FAILED=1
  exit 1
fi

# Extract text (prefer UTF-8)
if command -v pdftotext >/dev/null 2>&1; then
  pdftotext -q -enc UTF-8 -layout "$PDF_FILE" "$TXT_FILE" || true
else
  strings -a "$PDF_FILE" > "$TXT_FILE" || true
  warn "pdftotext not available; used strings fallback (less reliable)"
fi

# Required tokens
grep -Fq -- "$CREDIX_EXPECT_1" "$TXT_FILE" || { err "Expected string 1 not found: $CREDIX_EXPECT_1"; FAILED=1; exit 1; }
grep -Fq -- "$CREDIX_EXPECT_2" "$TXT_FILE" || { err "Expected string 2 not found: $CREDIX_EXPECT_2"; FAILED=1; exit 1; }

# Diacritics check:
# - Pass if we find Číslo
# - Fail hard if we find the classic broken rendering symptom: íslo / ?íslo
if grep -Fq -- "$CREDIX_EXPECT_CZ" "$TXT_FILE"; then
  log "Diacritics check OK: found '$CREDIX_EXPECT_CZ' in extracted text."
else
  if grep -Eq -- '(^|[^[:alpha:]])[?]?íslo([^[:alpha:]]|$)' "$TXT_FILE"; then
    err "Czech diacritics check failed: looks like 'Číslo' degraded to 'íslo' (missing glyph)."
    warn "Context around 'slo':"
    grep -n -C 2 -E 'íslo|slo' "$TXT_FILE" | head -n 80 >&2 || true
    FAILED=1
    exit 1
  fi

  err "Czech diacritics check failed: '$CREDIX_EXPECT_CZ' not found (and no obvious 'íslo' symptom either)."
  warn "Context around 'slo' (if any):"
  grep -n -C 2 -E 'slo|Slo' "$TXT_FILE" | head -n 80 >&2 || true
  FAILED=1
  exit 1
fi

# Font embedding check (recommended)
if command -v pdffonts >/dev/null 2>&1; then
  pdffonts "$PDF_FILE" > "$FONTS_FILE" || true

  if ! awk 'NR>2 {print}' "$FONTS_FILE" | grep -Eq '(^|[[:space:]])yes([[:space:]]|$)'; then
    err "Font embedding check failed: no embedded fonts detected in PDF"
    FAILED=1
    exit 1
  fi
else
  warn "pdffonts not available; skipping embedded font check (install poppler-utils for stronger coverage)"
fi

log "SUCCESS: Credix PDF contains expected strings + Czech diacritics, and fonts are embedded (if pdffonts present)."
FAILED=0
exit 0
