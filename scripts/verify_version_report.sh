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

# Ensure report files are available in the correct folder (discover it)
discover_report_dir() {
  local notes=""
  local webxml="$BIRT_WEBAPP/WEB-INF/web.xml"
  if docker exec "$CONTAINER_NAME" test -f "$webxml"; then
    local wf
    wf=$(docker exec "$CONTAINER_NAME" sh -lc "awk 'BEGIN{IGNORECASE=1}/BIRT_VIEWER_WORKING_FOLDER/{f=1} f&&/<param-value>/{gsub(/<\\/?.*?>/,\"\");print; exit}' '$webxml' | xargs echo -n") || true
    if [[ -n "$wf" ]]; then
      notes+="Found BIRT_VIEWER_WORKING_FOLDER in web.xml: $wf\n"
      echo "$wf"; echo -e "$notes" > "$REPORT_DIR_DISCOVERY_FILE"; return 0
    else
      notes+="Param BIRT_VIEWER_WORKING_FOLDER not found in web.xml.\n"
    fi
  else
    notes+="web.xml not found at $webxml.\n"
  fi
  local grep_out
  grep_out=$(docker exec "$CONTAINER_NAME" sh -lc "grep -RInE 'BIRT_VIEWER_WORKING_FOLDER|WORKING_FOLDER|reportFolder|resource|reports' '$BIRT_WEBAPP'/WEB-INF 2>/dev/null | head -n 50") || true
  if [[ -n "$grep_out" ]]; then notes+="Config hits:\n$grep_out\n"; fi
  local rpt
  rpt=$(docker exec "$CONTAINER_NAME" sh -lc "find '$BIRT_WEBAPP' -maxdepth 4 -type f -name '*.rptdesign' 2>/dev/null | head -n1") || true
  if [[ -n "$rpt" ]]; then
    local dir; dir=$(dirname "$rpt")
    notes+="Found existing .rptdesign: $rpt -> using $dir\n"
    echo "$dir"; echo -e "$notes" > "$REPORT_DIR_DISCOVERY_FILE"; return 0
  fi
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
  fi
  echo "$code"
}

append_params() {
  local base="$1"
  if [[ "$base" == *"?"* || "$base" == *"&"* || "$base" == *"__report="* ]]; then
    if [[ "$base" != *"__report="* ]]; then base+="&__report=${REPORT_FILE}"; fi
    if [[ "$base" != *"__format="* ]]; then base+="&__format=${REPORT_FORMAT}"; fi
  else
    base+="?__report=${REPORT_FILE}&__format=${REPORT_FORMAT}"
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
  if obvious_error "$bodyfile" || obvious_error "$HEADERS_FILE"; then warn "Obvious error detected for $url"; return 1; fi
  # In newer BIRT packs, index.jsp may ignore __report and show the viewer home. Reject that.
  if grep -qi "BIRT Viewer Installation" "$bodyfile"; then warn "Viewer index page detected for $url"; return 1; fi
  echo "$url"; return 0
}

# 1) HTTP discovery: fetch /birt and parse links
http_discover() {
  local bases=("${BASE_URL}/birt" "${BASE_URL}/birt/" "${BASE_URL}/birt/run" "${BASE_URL}/birt/frameset")
  local candidates=()
  for b in "${bases[@]}"; do
    log "HTTP discovery: probing $b"
    local code; code=$(fetch_url "$b")
    local ct; ct=$(grep -i '^Content-Type:' "$HEADERS_FILE" | tail -n1 | awk '{print tolower($0)}')
    if [[ "$code" == "200" ]] && echo "$ct" | grep -q 'text/html'; then
      cp -f "$BODY_HTML" "$DISCOVERY_HTML" 2>/dev/null || true
      local links
      links=$(grep -Eoi 'href\s*=\s*"[^"]+"|src\s*=\s*"[^"]+"' "$DISCOVERY_HTML" | sed -E 's/^[^\"]+"(.*)"/\1/' | sed 's/#.*$//' | sort -u)
      while IFS= read -r L; do
        [[ -z "$L" ]] && continue
        if echo "$L" | grep -Eqi 'frameset|run|preview|report|viewer|servlet|__report|__format'; then
          local path="$L"
          if [[ "$path" == http* ]]; then
            :
          elif [[ "$path" == /* ]]; then
            path="$path"
          else
            path="/birt/${path}"
          fi
          path="${path%%\?*}"
          if [[ "$path" == http* || "$path" == /birt/* ]]; then
            candidates+=("$path")
          fi
        fi
      done <<< "$links"
    fi
  done
  if [[ ${#candidates[@]} -gt 0 ]]; then
    local seen=()
    local ordered=()
    # Prefer non-JSP endpoints (run/frameset) before JSP index pages
    for p in "${candidates[@]}"; do [[ "$p" != *.jsp* ]] && ordered+=("$p"); done
    for p in "${candidates[@]}"; do [[ "$p" == *.jsp* ]] && ordered+=("$p"); done
    for p in "${ordered[@]}"; do
      [[ " ${seen[*]} " == *" $p "* ]] && continue
      seen+=("$p")
      if SELECTED=$(try_endpoint_url "$p"); then echo "$SELECTED"; return 0; fi
    done
  fi
  return 1
}

# 2) Container discovery: use gathered mappings and JSPs
container_discover() {
  log "Container discovery: analyzing servlet mappings and JSPs"
  local patterns
  patterns=$(grep -Eo '<url-pattern>[^<]+' "$SERVLET_MAP_FILE" | sed 's/<url-pattern>//g' | tr -d '\r' | sed 's/\s\+$//' | sort -u) || true
  local candidates=()
  while IFS= read -r pat; do
    [[ -z "$pat" ]] && continue
    if ! echo "$pat" | grep -Eqi 'frameset|run|preview|report|viewer'; then
      continue
    fi
    local base="$pat"
    case "$base" in
      */\*) base="${base%/\*}";;
      *\*) base="${base%\*}";;
    esac
    [[ "$base" != /* ]] && base="/$base"
    candidates+=("/birt${base}")
  done <<< "$patterns"

  for name in frameset.jsp run.jsp viewer.jsp report.jsp index.jsp; do
    if grep -q "/$name$" "$JSP_LIST_FILE"; then candidates+=("/birt/$name"); fi
  done

  if [[ ${#candidates[@]} -gt 0 ]]; then
    local seen=()
    local uniq=()
    for p in "${candidates[@]}"; do
      [[ " ${seen[*]} " == *" $p "* ]] && continue
      seen+=("$p"); uniq+=("$p")
    done
    for p in "${uniq[@]}"; do
      if SELECTED=$(try_endpoint_url "$p"); then echo "$SELECTED"; return 0; fi
    done
  fi
  return 1
}

SELECTED_URL=""
if [[ -n "$REPORT_PATH" ]]; then
  log "REPORT_PATH provided: $REPORT_PATH (skipping discovery)"
  if SELECTED_URL=$(try_endpoint_url "$REPORT_PATH"); then :; else err "Provided REPORT_PATH is not working"; exit 1; fi
else
  log "Starting endpoint discovery"
  if SELECTED_URL=$(http_discover); then
    log "HTTP discovery succeeded: $SELECTED_URL"
  elif SELECTED_URL=$(container_discover); then
    log "Container discovery succeeded: $SELECTED_URL"
  else
    warn "Discovery failed; falling back to standard candidates"
    fallback=("/birt/run" "/birt/frameset" "/viewer/run" "/viewer/frameset" "/birt-viewer/run" "/birt-viewer/frameset")
    for p in "${fallback[@]}"; do
      if SELECTED=$(try_endpoint_url "$p"); then SELECTED_URL="$SELECTED"; break; fi
    done
    [[ -n "$SELECTED_URL" ]] || { err "Failed to find a working report endpoint"; exit 1; }
  fi
fi

log "Selected endpoint: $SELECTED_URL"

# Verification request
VERIFY_URL="$SELECTED_URL"
# Try to prefer non-framed, non-index endpoints for content verification, but fall back if not valid
orig_url="$VERIFY_URL"
path="${orig_url%%\?*}"
qs="${orig_url#${path}}"
run_path="$path"
run_path="${run_path//index.jsp/run}"
run_path="${run_path//viewer.jsp/run}"
run_path="${run_path//frameset.jsp/run}"
run_path="${run_path/\/frameset/\/run}"
run_path="${run_path/\/preview/\/run}"
# If discovery landed on /birt (root) or index.jsp, force run
  [[ "$run_path" == */birt ]] && run_path="${run_path}/run"
  run_url="${run_path}${qs}"

# Test run_url quickly; if bad, keep original
: > "$HEADERS_FILE"; : > "$BODY_HTML"; : > "$BODY_TXT"; : > "$BODY_PDF"
HTTP_CODE=$(fetch_url "$run_url")
bodyfile="$BODY_HTML"; if [[ -s "$BODY_TXT" && "$REPORT_FORMAT" == "pdf" ]]; then bodyfile="$BODY_TXT"; fi
if [[ "$HTTP_CODE" == "200" && -s "$bodyfile" ]] && ! obvious_error "$bodyfile" && ! obvious_error "$HEADERS_FILE"; then
  if grep -qi "BIRT Viewer Installation" "$bodyfile"; then
    VERIFY_URL="$orig_url"
  else
    VERIFY_URL="$run_url"
  fi
else
  VERIFY_URL="$orig_url"
fi


log "Verification URL: $VERIFY_URL"

: > "$HEADERS_FILE"; : > "$BODY_HTML"; : > "$BODY_TXT"; : > "$BODY_PDF"
HTTP_CODE=$(fetch_url "$VERIFY_URL")
if [[ "$HTTP_CODE" != "200" ]]; then
  err "Verification request failed with HTTP $HTTP_CODE"
  err "URL used: $VERIFY_URL"
  FAILED=1
  exit 1
fi

BODY_FILE="$BODY_HTML"; if [[ -s "$BODY_TXT" && "$REPORT_FORMAT" == "pdf" ]]; then BODY_FILE="$BODY_TXT"; fi
[[ -s "$BODY_FILE" ]] || { err "Empty verification body"; err "URL used: $VERIFY_URL"; FAILED=1; exit 1; }

if obvious_error "$BODY_FILE" || obvious_error "$HEADERS_FILE"; then
  err "Obvious error in verification response"
  err "URL used: $VERIFY_URL"
  FAILED=1
  exit 1
fi

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
CREDIX_ENDPOINT_PATH=${CREDIX_ENDPOINT_PATH:-/birt/frameset}
CREDIX_FORMAT=${CREDIX_FORMAT:-pdf}

log "Credix config: REPORT=$CREDIX_REPORT_NAME XML=$CREDIX_XML_FILE_URL EXPECT_1=$CREDIX_EXPECT_1 EXPECT_2=$CREDIX_EXPECT_2 ENDPOINT=$CREDIX_ENDPOINT_PATH FORMAT=$CREDIX_FORMAT"

# 1) Verify report exists in container
if ! docker exec "$CONTAINER_NAME" test -f "/opt/tomcat/webapps/birt/$CREDIX_REPORT_NAME"; then
  warn "Listing /opt/tomcat/webapps/birt contents:"
  docker exec "$CONTAINER_NAME" ls -la /opt/tomcat/webapps/birt || true
  err "Credix report not found in container: /opt/tomcat/webapps/birt/$CREDIX_REPORT_NAME"
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
CREDIX_URL="${BASE_URL}${CREDIX_ENDPOINT_PATH}?xml_file=${ENC_XML}&__format=${CREDIX_FORMAT}&__report=${CREDIX_REPORT_NAME}"
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

