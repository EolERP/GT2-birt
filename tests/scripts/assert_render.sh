#!/usr/bin/env bash
set -euo pipefail
FILE="${1:-}"
STATUS_FILE="${2:-}"
EXPECT1="${3:-SMOKE_OK}"
EXPECT2="${4:-TOTAL=3}"

[ -f "$FILE" ] || { echo "Rendered file missing: $FILE"; exit 1; }
[ -s "$FILE" ] || { echo "Rendered file empty: $FILE"; exit 1; }
SIZE=$(stat -c%s "$FILE")
if [ "$SIZE" -le 1024 ]; then
  echo "Rendered file too small: ${SIZE} bytes"; exit 1;
fi

CODE=""
[ -f "$STATUS_FILE" ] && CODE=$(cat "$STATUS_FILE") || true
if [ "$CODE" != "200" ]; then
  echo "HTTP status not 200: '$CODE'"; exit 1
fi

grep -q "$EXPECT1" "$FILE" || { echo "Missing expected string: $EXPECT1"; exit 1; }
grep -q "$EXPECT2" "$FILE" || { echo "Missing expected string: $EXPECT2"; exit 1; }

echo "Assertions OK"
