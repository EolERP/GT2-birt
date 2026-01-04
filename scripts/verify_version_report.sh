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
# ODA XML test env
SKIP_ODA_XML_TEST=${SKIP_ODA_XML_TEST:-}
ODA_XML_EXPECTED=${ODA_XML_EXPECTED:-ODA_XML_OK}
ODA_XML_REPORT=${ODA_XML_REPORT:-oda_xml_test.rptdesign}
ODA_XML_DATA=${ODA_XML_DATA:-oda_xml_test.xml}
ODA_XML_JAR_URL=${ODA_XML_JAR_URL:-https://download.eclipse.org/releases/2021-03/202103171000/plugins/org.eclipse.datatools.enablement.oda.xml_1.4.102.201901091730.jar}
ODA_XML_RESTART=${ODA_XML_RESTART:-1}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Temp files
TMP_DIR=${TMP_DIR:-"$(mktemp -d)"}
HEADERS_FILE="$TMP_DIR/headers.txt"
RESPONSE_FILE="$TMP_DIR/response.bin"
BODY_HTML="$TMP_DIR/body.html"
BODY_PDF="$TMP_DIR/body.pdf"
BODY_TXT="$TMP_DIR/body.txt"
DISCOVERY_HTML="$TMP_DIR/birt_index.html"
SERVLET_MAP_FILE="$TMP_DIR/servlet_mappings.txt"
JSP_LIST_FILE="$TMP_DIR/jsp_list.txt"
REPORT_DIR_DISCOVERY_FILE="$TMP_DIR/report_dir_discovery.txt"
WORKING_FOLDER=""

FAILED=1

log() { echo "[verify] $*" >&2; }
warn() { echo "[verify][WARN] $*" >&2; }
err() { echo "[verify][ERROR] $*" >&2; }

cleanup() {
  local code=$?
  if [[ $FAILED -ne 0 ]]; then
    warn "Collecting diagnostics before cleanup..."

    # Save response artifacts for version report
    mkdir -p out || true
    if [[ -s "$BODY_HTML" ]]; then
      cp -f "$BODY_HTML" out/version_response.html 2>/dev/null || true
    fi
    if [[ -s "$BODY_TXT" ]]; then
      cp -f "$BODY_TXT" out/version_response.txt 2>/dev/null || true
    fi

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
    if [[ -s "$SERVLET_MAP_FILE" ]]; then
      warn "Servlet mappings and url-patterns:"
      sed 's/^/[mapping] /' "$SERVLET_MAP_FILE" >&2
    fi
    if [[ -s "$JSP_LIST_FILE" ]]; then
      warn "Relevant JSP/HTML under webapp:"
      sed 's/^/[jsp] /' "$JSP_LIST_FILE" >&2
    fi
    if [[ -s "$REPORT_DIR_DISCOVERY_FILE" ]]; then
      warn "Report folder discovery notes:"
      sed 's/^/[report-dir] /' "$REPORT_DIR_DISCOVERY_FILE" >&2
    fi

    if command -v docker >/dev/null 2>&1; then
      # A) Confirm reports presence
      warn "Listing /opt/tomcat/webapps/birt (first 200 entries):"
      docker exec "$CONTAINER_NAME" sh -lc 'ls -la /opt/tomcat/webapps/birt | head -200' 2>&1 | sed 's/^/[container ls] /' >&2 || true
      warn "Listing /opt/tomcat/webapps/birt/WEB-INF (first 200 entries):"
      docker exec "$CONTAINER_NAME" sh -lc 'ls -la /opt/tomcat/webapps/birt/WEB-INF | head -200' 2>&1 | sed 's/^/[container ls] /' >&2 || true
      warn "Finding report design files (maxdepth 2):"
      docker exec "$CONTAINER_NAME" sh -lc 'find /opt/tomcat/webapps/birt -maxdepth 2 \( -name "version.rptdesign" -o -name "credix_repayment_schedule.rptdesign" \) -print' 2>&1 | sed 's/^/[container find] /' >&2 || true

      # B) Viewer configuration: save head snippets and effective params
      warn "Saving viewer config head to out/viewer-config-head.txt"
      docker exec "$CONTAINER_NAME" sh -lc '
        for f in /opt/tomcat/webapps/birt/WEB-INF/web.xml /opt/tomcat/webapps/birt/WEB-INF/web-viewer.xml; do
          [ -f "$f" ] || continue;
          echo "== $f ==";
          awk "NR>=1&&NR<=200{print}" "$f" | sed -n "1,200p" | cat;
        done
      ' > out/viewer-config-head.txt 2>&1 || true

      warn "Extracting effective viewer param values to out/viewer-effective-params.txt"
      docker exec "$CONTAINER_NAME" sh -lc '
        set -e; OUT="/tmp/viewer-effective-params.txt"; : > "$OUT" || true;
        extract_with_xmlstarlet() {
          local f="$1";
          xmlstarlet sel -t \
            -m "//context-param[param-name='BIRT_VIEWER_WORKING_FOLDER' or param-name='WORKING_FOLDER_ACCESS_ONLY' or param-name='URL_REPORT_PATH_POLICY' or starts-with(param-name,'URL_REPORT_')]" \
            -v "concat(param-name, '=', normalize-space(param-value))" -n "$f" 2>/dev/null || true;
        }
        extract_with_awk() {
          awk '
            BEGIN{IGNORECASE=1; key=""}
            /<context-param>/{inctx=1}
            inctx && /<param-name>/ {
              match($0, /<param-name>\s*([^<]+)\s*<\\/param-name>/, m); if (m[1] != "") key=m[1];
            }
            inctx && /<param-value>/ && key != "" {
              match($0, /<param-value>\s*([^<]+)\s*<\\/param-value>/, v);
              if (v[1] != "") {
                if (key ~ /^(BIRT_VIEWER_WORKING_FOLDER|WORKING_FOLDER_ACCESS_ONLY|URL_REPORT_PATH_POLICY|URL_REPORT_.*)$/) {
                  gsub(/\r|\n/, "", v[1]); print key "=" v[1];
                }
                key="";
              }
            }
            /<\\/context-param>/{inctx=0}
          ' "$1" 2>/dev/null || true;
        }
        for f in /opt/tomcat/webapps/birt/WEB-INF/web.xml /opt/tomcat/webapps/birt/WEB-INF/web-viewer.xml; do
          [ -f "$f" ] || continue;
          echo "== $f ==" >> "$OUT";
          if command -v xmlstarlet >/dev/null 2>&1; then extract_with_xmlstarlet "$f" >> "$OUT"; else extract_with_awk "$f" >> "$OUT"; fi
        done;
        cat "$OUT"
      ' > out/viewer-effective-params.txt 2>&1 || true

      # Echo key evidence directly into job log (source of truth)
      if [[ -f out/viewer-effective-params.txt ]]; then
        warn "=== Effective viewer params (echo) ==="
        sed -n '1,200p' out/viewer-effective-params.txt | sed 's/^/[viewer-param] /' >&2 || true
      fi
      if [[ -f out/viewer-config-head.txt ]]; then
        warn "=== Context-param blocks from viewer-config-head (echo) ==="
        awk '/<context-param>/{p=1} p{print} /<\/context-param>/{p=0}' out/viewer-config-head.txt | sed -n '1,400p' | sed 's/^/[viewer-conf] /' >&2 || true
      fi

      # C) Docker logs tail saved to out/
      docker logs "$CONTAINER_NAME" | tail -400 > out/docker-logs-tail.txt 2>/dev/null || true
      warn "Saved docker logs tail to out/docker-logs-tail.txt"

      # D) Save Credix response preview if present
      if [[ -f out/credix_body_preview.txt ]]; then
        cp -f out/credix_body_preview.txt out/credix_response.txt 2>/dev/null || true
      fi
    fi

    # Also echo last verification URL and response head directly
    if [[ -n "${VERIFY_URL:-}" ]]; then warn "Last verification URL: ${VERIFY_URL}"; fi
    if [[ -s "$BODY_TXT" ]]; then
      warn "Response text (first 200 lines):"; sed -n '1,200p' "$BODY_TXT" | sed 's/^/[text-ln] /' >&2 || true
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

# Validate inputs
[[ -f "$REPO_ROOT/$REPORT_FILE" ]] || { err "Report file not found: $REPO_ROOT/$REPORT_FILE"; exit 1; }
[[ -f "$REPO_ROOT/$EXPECTED_FILE" ]] || { err "Expected value file not found: $REPO_ROOT/$EXPECTED_FILE"; exit 1; }

EXPECTED_VALUE=$(head -n1 "$REPO_ROOT/$EXPECTED_FILE" | tr -d '\r' | sed -e 's/^\s\+//' -e 's/\s\+$//')
[[ -n "$EXPECTED_VALUE" ]] || { err "Expected value from $EXPECTED_FILE is empty"; exit 1; }
log "Expected value: '$EXPECTED_VALUE'"

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

# Wait until ready
wait_ready() {
  local start_ts
  start_ts=$(date +%s)
  local deadline
  deadline=$((start_ts + TIMEOUT_SEC))
  while (( $(date +%s) <= deadline )); do
    if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "Server startup in"; then return 0; fi
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 "$BASE_URL" || true)
    if [[ "$code" != "000" ]]; then return 0; fi
    sleep 2
  done
  return 1
}
log "Waiting for service readiness (timeout ${TIMEOUT_SEC}s)"
wait_ready || { err "Service did not become ready in ${TIMEOUT_SEC}s"; exit 1; }

# Determine BIRT webapp root
BIRT_WEBAPP="/opt/tomcat/webapps/birt"
if ! docker exec "$CONTAINER_NAME" test -d "$BIRT_WEBAPP"; then
  log "Searching for BIRT webapp under /opt/tomcat/webapps ..."
  BIRT_WEBAPP=$(docker exec "$CONTAINER_NAME" sh -lc 'for d in /opt/tomcat/webapps/*; do [ -d "$d" ] && [ -e "$d/WEB-INF/web.xml" ] && basename "$d" | grep -qi birt && echo "$d"; done | head -n1')
  [[ -n "$BIRT_WEBAPP" ]] || { err "Cannot locate BIRT webapp"; exit 1; }
fi
log "BIRT webapp root: $BIRT_WEBAPP"

# For BIRT 4.18+, use the 'report' subfolder as report root when present
REPORT_ROOT_CAND="$BIRT_WEBAPP/report"
if docker exec "$CONTAINER_NAME" test -d "$REPORT_ROOT_CAND"; then
  REPORT_DIR="$REPORT_ROOT_CAND"
fi

# Always gather container intel for diagnostics
gather_container_intel() {
  local webxml="$BIRT_WEBAPP/WEB-INF/web.xml"
  if docker exec "$CONTAINER_NAME" test -f "$webxml"; then
    docker exec "$CONTAINER_NAME" sh -lc "awk '/<servlet-mapping>/{f=1} f; /<\\/servlet-mapping>/{print; f=0}' '$webxml'" > "$SERVLET_MAP_FILE" || true
  else
    echo "web.xml not found at $webxml" > "$SERVLET_MAP_FILE"
  fi
  docker exec "$CONTAINER_NAME" sh -lc "find '$BIRT_WEBAPP' -maxdepth 3 -type f \( -name '*.jsp' -o -name '*.do' -o -name '*.html' \) | sort" > "$JSP_LIST_FILE" || true
}
gather_container_intel

# Ensure report files are available in the correct folder (discover viewer working folder if set)
discover_report_dir() {
  local notes=""

  local webxml="$BIRT_WEBAPP/WEB-INF/web.xml"
  local webviewerxml="$BIRT_WEBAPP/WEB-INF/web-viewer.xml"
  local wf=""

  if docker exec "$CONTAINER_NAME" test -f "$webxml"; then
    wf=$(docker exec "$CONTAINER_NAME" sh -lc "awk 'BEGIN{IGNORECASE=1}/BIRT_VIEWER_WORKING_FOLDER/{f=1} f&&/<param-value>/{gsub(/<\\/?.*?>/,\"\");print; exit}' '$webxml' | xargs echo -n") || true
    if [[ -n "$wf" ]]; then notes+="Found BIRT_VIEWER_WORKING_FOLDER in web.xml: $wf\n"; fi
  fi
  if [[ -z "$wf" ]] && docker exec "$CONTAINER_NAME" test -f "$webviewerxml"; then
    wf=$(docker exec "$CONTAINER_NAME" sh -lc "awk 'BEGIN{IGNORECASE=1}/BIRT_VIEWER_WORKING_FOLDER/{f=1} f&&/<param-value>/{gsub(/<\\/?.*?>/,\"\");print; exit}' '$webviewerxml' | xargs echo -n") || true
    if [[ -n "$wf" ]]; then notes+="Found BIRT_VIEWER_WORKING_FOLDER in web-viewer.xml: $wf\n"; fi
  fi

  if [[ -n "$wf" ]]; then
    # Make absolute if relative
    if [[ "$wf" != /* ]]; then wf="$BIRT_WEBAPP/$wf"; fi
    docker exec "$CONTAINER_NAME" sh -lc "mkdir -p '$wf'" >/dev/null 2>&1 || true
    WORKING_FOLDER="$wf"
    echo "$wf"; echo -e "$notes" > "$REPORT_DIR_DISCOVERY_FILE"; return 0
  fi

  # Heuristic fallbacks commonly used by BIRT viewer
  for cand in "$BIRT_WEBAPP/report"; do
    notes+="Using standard report folder: $cand\n"
    docker exec "$CONTAINER_NAME" sh -lc "mkdir -p '$cand'" >/dev/null 2>&1 || true
    echo "$cand"; echo -e "$notes" > "$REPORT_DIR_DISCOVERY_FILE"; return 0
  done

  # Last resort: webapp root (kept for diagnostics consistency)
  notes+="Falling back to webapp root: $BIRT_WEBAPP\n"
  echo "$BIRT_WEBAPP"; echo -e "$notes" > "$REPORT_DIR_DISCOVERY_FILE"; return 0
}
if [[ -n "$REPORT_DIR" ]]; then
  REPORT_TARGET_DIR="$REPORT_DIR"
  echo "REPORT_DIR overridden by env: $REPORT_TARGET_DIR" > "$REPORT_DIR_DISCOVERY_FILE"
else
  REPORT_TARGET_DIR=$(discover_report_dir)
fi
log "Report target directory in container: $REPORT_TARGET_DIR"

# Use discovered folder; avoid forcing subfolder that may be restricted in newer BIRT
log "Using discovered report dir: $REPORT_TARGET_DIR"

# Build report param deterministically: bare file name only
REPORT_PARAM="$(basename -- "$REPORT_FILE")"
log "Resolved __report param (bare): $REPORT_PARAM"
if [[ -n "$WORKING_FOLDER" ]]; then
  warn "Detected working folder: $WORKING_FOLDER"
fi


# Copy report assets if missing
if ! docker exec "$CONTAINER_NAME" test -f "$REPORT_TARGET_DIR/$REPORT_FILE"; then
  log "Copying $REPORT_FILE -> $REPORT_TARGET_DIR"; docker cp "$REPO_ROOT/$REPORT_FILE" "$CONTAINER_NAME:$REPORT_TARGET_DIR/"
fi
if ! docker exec "$CONTAINER_NAME" test -f "$REPORT_TARGET_DIR/$EXPECTED_FILE"; then
  log "Copying $EXPECTED_FILE -> $REPORT_TARGET_DIR"; docker cp "$REPO_ROOT/$EXPECTED_FILE" "$CONTAINER_NAME:$REPORT_TARGET_DIR/"
fi

# Helpers
obvious_error() { grep -qiE "Exception|Whitelabel|HTTP Status|Not Found|404|500|Stacktrace|SEVERE|There was an error" "$1"; }

fetch_url() {
  local url="$1"
  : > "$HEADERS_FILE"; : > "$RESPONSE_FILE"
  local code
  code=$(curl -sS -L -D "$HEADERS_FILE" -o "$RESPONSE_FILE" --max-time 90 "$url" -w "%{http_code}" || true)
  local ct; ct=$(grep -i '^Content-Type:' "$HEADERS_FILE" | tail -n1 | awk '{print tolower($0)}')
  if echo "$ct" | grep -q 'pdf'; then
    mv "$RESPONSE_FILE" "$BODY_PDF" 2>/dev/null || true
    if command -v pdftotext >/dev/null 2>&1; then pdftotext -q "$BODY_PDF" "$BODY_TXT" || true; else strings "$BODY_PDF" > "$BODY_TXT" || true; fi
  else
    mv "$RESPONSE_FILE" "$BODY_HTML" 2>/dev/null || true
    # Also create a crude text version for token searches
    sed -E 's/<[^>]+>/\n/g' "$BODY_HTML" | sed -E 's/&nbsp;/ /g' | tr -s '\n' > "$BODY_TXT" || true
  fi
  echo "$code"
}

append_params() {
  local base="$1"
  # Use standard __report and __format for all endpoints, including /preview
  local repkey="__report"; local fmtkey="__format"
  if [[ "$base" == *"?"* || "$base" == *"&"* || "$base" == *"${repkey}="* ]]; then
    if [[ "$base" != *"${repkey}="* ]]; then base+="&${repkey}=${REPORT_PARAM}"; fi
    if [[ "$base" != *"${fmtkey}="* ]]; then base+="&${fmtkey}=${REPORT_FORMAT}"; fi
  else
    base+="?${repkey}=${REPORT_PARAM}&${fmtkey}=${REPORT_FORMAT}"
  fi
  echo "$base"
}

try_endpoint_url() {
  local raw="$1"; local url
  if [[ "$raw" == http* ]]; then url="$raw"; else url="${BASE_URL}${raw}"; fi
  url=$(append_params "$url")
  log "Trying endpoint: $url"
  local code; code=$(fetch_url "$url")
  if [[ "$code" != "200" ]]; then warn "HTTP $code for $url"; return 1; fi
  local bodyfile="$BODY_HTML"; if [[ -s "$BODY_TXT" && "$REPORT_FORMAT" == "pdf" ]]; then bodyfile="$BODY_TXT"; fi
  if [[ ! -s "$bodyfile" ]]; then warn "Empty body for $url"; return 1; fi
  # In newer BIRT packs, index.jsp may ignore __report and show the viewer home. Reject that.
  if grep -qi "BIRT Viewer Installation" "$bodyfile"; then warn "Viewer index page detected for $url"; return 1; fi
  echo "$url"; return 0
}

# Deterministic endpoint selection for BIRT 4.18+
# Use /preview for direct render without viewer shell/AJAX
SELECTED_URL="${BASE_URL}/birt/preview"
# Build URL with relative report path against report root
SELECTED_URL=$(append_params "$SELECTED_URL")

log "Selected endpoint: $SELECTED_URL"

# Verification request
VERIFY_URL="$SELECTED_URL"
# Deterministic verification URL
VERIFY_URL="$SELECTED_URL"
log "Verification URL: $VERIFY_URL"

try_verify_with_url() {
  local url="$1"
  : > "$HEADERS_FILE"; : > "$BODY_HTML"; : > "$BODY_TXT"; : > "$BODY_PDF"
  local code; code=$(fetch_url "$url")
  if [[ "$code" != "200" ]]; then
    warn "HTTP $code for $url"
    return 1
  fi
  local bodyfile="$BODY_HTML"; if [[ -s "$BODY_TXT" && "$REPORT_FORMAT" == "pdf" ]]; then bodyfile="$BODY_TXT"; fi
  if [[ ! -s "$bodyfile" ]]; then warn "Empty body for $url"; return 1; fi
  if grep -qi "BIRT Viewer Installation" "$bodyfile"; then warn "Viewer index page detected for $url"; return 1; fi
  if grep -qi "There is no report design object available" "$bodyfile"; then warn "Viewer error: no report design for $url"; return 1; fi
  # Accept HTML or PDF; only treat as error if still no expected token later
  echo "$url"; return 0
}

if SELECTED=$(try_verify_with_url "$VERIFY_URL"); then
  VERIFY_URL="$SELECTED"
else
  err "Verification failed"
  err "URL used: $VERIFY_URL"
  FAILED=1
  exit 1
fi

BODY_FILE="$BODY_HTML"; if [[ -s "$BODY_TXT" && "$REPORT_FORMAT" == "pdf" ]]; then BODY_FILE="$BODY_TXT"; fi

if ! grep -Fq -- "$EXPECTED_VALUE" "$BODY_FILE"; then
  err "Expected value NOT found in report output"
  err "Expected: $EXPECTED_VALUE"
  err "URL used: $VERIFY_URL"
  warn "Relevant headers:"
  grep -Ei '^(HTTP/|Server:|Content-Type:|Location:)' "$HEADERS_FILE" | sed 's/^/[headers] /' >&2 || true
  FAILED=1
  exit 1
fi

log "SUCCESS: Found expected value '$EXPECTED_VALUE' in response."

# ==========================
# Credix PDF E2E verification
# ==========================
# Configurable variables with defaults
CREDIX_REPORT_NAME=${CREDIX_REPORT_NAME:-credix_repayment_schedule.rptdesign}
CREDIX_XML_FILE_URL=${CREDIX_XML_FILE_URL:-https://gist.githubusercontent.com/dpodhola-eolerp/16266ad29c3bc8309c6601e2c15ac3d8/raw/4612297f7613d063ce2d0cf64e2f554ef6b03d7b/data.xml}
CREDIX_EXPECT_1=${CREDIX_EXPECT_1:-E2E_TEST_CredixBankAccount_123}
CREDIX_EXPECT_2=${CREDIX_EXPECT_2:-E2E_TEST_SCONT_Value_123}
CREDIX_ENDPOINT_PATH=${CREDIX_ENDPOINT_PATH:-/birt/preview}
CREDIX_FORMAT=${CREDIX_FORMAT:-pdf}

log "Credix config: REPORT=$CREDIX_REPORT_NAME XML=$CREDIX_XML_FILE_URL EXPECT_1=$CREDIX_EXPECT_1 EXPECT_2=$CREDIX_EXPECT_2 ENDPOINT=$CREDIX_ENDPOINT_PATH FORMAT=$CREDIX_FORMAT"

# 1) Verify report exists in container (support new documents/ baseline)
if ! docker exec "$CONTAINER_NAME" sh -lc "test -f '/opt/tomcat/webapps/birt/$CREDIX_REPORT_NAME' || test -f '/opt/tomcat/webapps/birt/report/$CREDIX_REPORT_NAME' || test -f '/opt/tomcat/webapps/birt/documents/$CREDIX_REPORT_NAME'"; then
  warn "Listing /opt/tomcat/webapps/birt contents:"
  docker exec "$CONTAINER_NAME" ls -la /opt/tomcat/webapps/birt || true
  warn "Listing /opt/tomcat/webapps/birt/report and /documents if present:"
  docker exec "$CONTAINER_NAME" sh -lc "ls -la /opt/tomcat/webapps/birt/report 2>/dev/null || true; ls -la /opt/tomcat/webapps/birt/documents 2>/dev/null || true" || true
  err "Credix report not found in expected locations: $CREDIX_REPORT_NAME"
  FAILED=1
  exit 1
fi

# Helper to URL-encode only the XML value
credix_urlencode() {
  local s="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$s"
  elif command -v python >/dev/null 2>&1; then
    python - "$s" <<'PY'
import sys, urllib
try:
    from urllib import quote  # py2
except Exception:
    from urllib.parse import quote  # py3
print(quote(sys.argv[1], safe=''))
PY
  else
    # Minimal fallback (not full RFC 3986)
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

# 2) Build URL
BASE_URL="http://localhost:${HOST_PORT:-8080}"
ENC_XML="$(credix_urlencode "$CREDIX_XML_FILE_URL")"
CREDIX_URL="${BASE_URL}${CREDIX_ENDPOINT_PATH}?__report=${CREDIX_REPORT_NAME}&__format=${CREDIX_FORMAT}&xml_file=${ENC_XML}"
log "Credix request URL: $CREDIX_URL"

# 3) Download output
mkdir -p out
if ! curl -fsSL -D out/credix_headers.txt "$CREDIX_URL" -o out/credix_report.pdf; then
  err "curl download failed for Credix report"
  FAILED=1
  exit 1
fi

# 4) Verify it is a PDF
if ! head -c 5 out/credix_report.pdf | grep -q "%PDF-"; then
  head -c 2000 out/credix_report.pdf > out/credix_body_preview.txt 2>/dev/null || true
  err "Credix response is not a PDF"
  FAILED=1
  exit 1
fi

# 5) Extract text
if command -v pdftotext >/dev/null 2>&1; then
  pdftotext -q out/credix_report.pdf out/credix_report.txt || true
else
  strings -a out/credix_report.pdf > out/credix_report.txt || true
fi

# 6) Verify expected content
if ! grep -Fq -- "$CREDIX_EXPECT_1" out/credix_report.txt; then
  err "Expected string 1 not found in PDF: $CREDIX_EXPECT_1"
  FAILED=1
  exit 1
fi
if ! grep -Fq -- "$CREDIX_EXPECT_2" out/credix_report.txt; then
  err "Expected string 2 not found in PDF: $CREDIX_EXPECT_2"
  FAILED=1
  exit 1
fi

log "SUCCESS: Credix PDF report contains expected strings."
FAILED=0
exit 0

