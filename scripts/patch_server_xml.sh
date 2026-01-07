#!/bin/sh
set -eu

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "Usage: $0 /path/to/server.xml" >&2
  exit 2
fi

echo "==== server.xml context (lines 150-180) BEFORE patch ===="
nl -ba "$FILE" | sed -n '150,180p' || true

# idempotence: if RemoteIpValve already present, do nothing
if grep -q 'org\.apache\.catalina\.valves\.RemoteIpValve' "$FILE"; then
  echo "RemoteIpValve already present; nothing to do."
  exit 0
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

valve='        <Valve className="org.apache.catalina.valves.RemoteIpValve"
               protocolHeader="x-forwarded-proto"
               protocolHeaderHttpsValue="https"
               portHeader="x-forwarded-port" />'

awk -v valve="$valve" '
BEGIN { in_host=0; inserted=0 }

# detect Host start (may be multi-line)
$0 ~ /<Host[[:space:]]/ { in_host=1 }

# while we are still in the Host start tag, print lines; when we hit the closing ">", insert valve after that line
in_host==1 {
  print
  if ($0 ~ />/) {
    print valve
    inserted=1
    in_host=0
  }
  next
}

{ print }

END {
  if (inserted==0) {
    print "ERROR: Could not find <Host ...> start tag to insert RemoteIpValve" > "/dev/stderr"
    exit 1
  }
}
' "$FILE" > "$tmp"

# Atomic replace + backup
cp "$FILE" "${FILE}.bak"
cat "$tmp" > "$FILE"

echo "Inserted RemoteIpValve into $FILE"
