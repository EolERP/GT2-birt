#!/usr/bin/env bash
set -euo pipefail
URL="${1:-}"
TIMEOUT="${2:-180}"
INTERVAL=3
START=$(date +%s)
[ -n "$URL" ] || { echo "URL required"; exit 2; }

while true; do
  CODE=$(curl -kLs -o /dev/null -w "%{http_code}" "$URL" || true)
  if [ "$CODE" = "200" ]; then
    echo "200" > artifacts/http_status.txt
    echo "Ready: $URL"
    exit 0
  fi
  NOW=$(date +%s)
  ELAPSED=$(( NOW - START ))
  if [ $ELAPSED -ge $TIMEOUT ]; then
    echo "Timeout waiting for $URL (last code=$CODE)" >&2
    exit 1
  fi
  sleep $INTERVAL
done
