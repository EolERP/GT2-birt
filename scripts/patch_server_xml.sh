#!/bin/sh
set -eu
FILE=${1:-/etc/tomcat/server.xml}
if [ ! -f "$FILE" ]; then
  echo "server.xml not found: $FILE" >&2
  exit 1
fi

# Print context around the problematic area for diagnostics (lines 150-180)
echo "==== server.xml context (lines 150-180) BEFORE patch ===="
sed -n '150,180p' "$FILE" || true

# Additionally, print the complete <Host ...> start tag and first few children
HOST_START_LINE=$(awk 'BEGIN{s=0}/<Host[[:space:]>]/{print NR; exit 0}' "$FILE" || true)
if [ -n "${HOST_START_LINE:-}" ]; then
  HOST_END_LINE=$(awk -v start="$HOST_START_LINE" 'NR>=start{print; if ($0 ~ />/) {print NR; exit 0}}' "$FILE" | tail -n1 || true)
  if [ -n "${HOST_END_LINE:-}" ]; then
    START=${HOST_START_LINE}
    END=$((HOST_END_LINE+5))
    echo "==== server.xml <Host> start tag and first children (lines ${START}-${END}) BEFORE patch ===="
    sed -n "${START},${END}p" "$FILE" || true
  fi
fi

# Idempotent: do nothing if RemoteIpValve already present inside <Host> ... </Host>
if awk 'BEGIN{IGNORECASE=1; inhost=0; found=0}
  /<Host([[:space:]>]|$)/{inhost=1}
  inhost && /<\/Host>/{inhost=0}
  inhost && /org\.apache\.catalina\.valves\.RemoteIpValve/{found=1}
  END{exit(found?0:1)}' "$FILE"; then
  echo "RemoteIpValve already configured inside <Host>; skipping"
  exit 0
fi

TMPFILE=$(mktemp)
awk '
  BEGIN{inserted=0; in_host_start=0}
  # Detect beginning of <Host ...>
  /<Host([[:space:]>]|$)/ && inserted==0 && in_host_start==0 {
    print
    if ($0 ~ />/) {
      # Host start tag is complete on this line -> insert Valve safely after it
      print "    <Valve className=\"org.apache.catalina.valves.RemoteIpValve\""
      print "           protocolHeader=\"x-forwarded-proto\""
      print "           protocolHeaderHttpsValue=\"https\""
      print "           portHeader=\"x-forwarded-port\" />"
      inserted=1
      next
    } else {
      # Host start tag spans multiple lines; defer insertion until we see the closing '>'
      in_host_start=1
      next
    }
  }
  # We are within a multi-line <Host ...> start tag; wait for the closing '>'
  in_host_start==1 {
    print
    if ($0 ~ />/) {
      print "    <Valve className=\"org.apache.catalina.valves.RemoteIpValve\""
      print "           protocolHeader=\"x-forwarded-proto\""
      print "           protocolHeaderHttpsValue=\"https\""
      print "           portHeader=\"x-forwarded-port\" />"
      inserted=1
      in_host_start=0
      next
    }
    next
  }
  {print}
  END{
    if (inserted==0) {
      print "Warning: <Host> element not found; RemoteIpValve not inserted" > "/dev/stderr";
      exit 1
    }
  }
' "$FILE" > "$TMPFILE"
cp "$TMPFILE" "$FILE"
rm -f "$TMPFILE"
echo "RemoteIpValve inserted into $FILE"
