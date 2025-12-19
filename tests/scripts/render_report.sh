#!/usr/bin/env bash
set -euo pipefail
BASE="${1:-}"
RPT="${2:-}"
FMT="${3:-html}"
OUT="${4:-artifacts/rendered.html}"
MODE="${5:-preview}"
[ -n "$BASE" ] && [ -n "$RPT" ] || { echo "Usage: render_report.sh <base> <report> [fmt] [out] [mode]"; exit 2; }

# Build URL; report file path must be relative to BIRT working folder (/opt/tomcat/webapps/birt)
# We mount ./tests at /opt/tomcat/webapps/birt/tests, so pass paths like tests/reports/smoke.rptdesign
RPT_PARAM="${RPT#./}"
URL="$BASE/$MODE?__report=$RPT_PARAM&__format=$FMT"

HTTP_CODE=$(curl -Ls -w "%{http_code}" -o "$OUT" "$URL" || true)

echo "$HTTP_CODE" > artifacts/http_status.txt

if [ "$HTTP_CODE" != "200" ]; then
  echo "Non-200 status: $HTTP_CODE for $URL" >&2
  exit 1
fi

# Success
exit 0
