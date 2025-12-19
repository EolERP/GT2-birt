#!/usr/bin/env bash
set -euo pipefail
BASES=(
  "http://localhost:8080/birt"
  "http://localhost:8080/birt/"
  "http://localhost:8080/WebViewerExample"
  "http://localhost:8080/WebViewerExample/"
)
CANDIDATES=(
  "preview"
  "frameset"
)

for B in "${BASES[@]}"; do
  CODE=$(curl -ks -o /dev/null -w "%{http_code}" "$B" || true)
  if [ "$CODE" = "200" ]; then
    echo "$B"; exit 0
  fi
  for C in "${CANDIDATES[@]}"; do
    CODE=$(curl -ks -o /dev/null -w "%{http_code}" "$B/$C" || true)
    if [ "$CODE" = "200" ]; then
      echo "$B"; exit 0
    fi
  done
done

echo "No working viewer base found" >&2
exit 1
