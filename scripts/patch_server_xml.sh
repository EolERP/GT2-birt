#!/bin/sh
set -eu
FILE=${1:-/etc/tomcat/server.xml}
if [ ! -f "$FILE" ]; then
  echo "server.xml not found: $FILE" >&2
  exit 1
fi
# Idempotent: do nothing if RemoteIpValve already present
if grep -qi "org.apache.catalina.valves.RemoteIpValve" "$FILE"; then
  echo "RemoteIpValve already configured; skipping"
  exit 0
fi
TMPFILE=$(mktemp)
awk '
  BEGIN{inserted=0}
  /<Host[[:space:]>]/ && inserted==0 {
    print
    print "    <Valve className=\"org.apache.catalina.valves.RemoteIpValve\""
    print "           protocolHeader=\"x-forwarded-proto\""
    print "           protocolHeaderHttpsValue=\"https\""
    print "           portHeader=\"x-forwarded-port\" />"
    inserted=1
    next
  }
  {print}
  END{ if (inserted==0) { 
         print "Warning: <Host> element not found; RemoteIpValve not inserted" > "/dev/stderr"; 
         exit 1 
       } }
' "$FILE" > "$TMPFILE"
cp "$TMPFILE" "$FILE"
rm -f "$TMPFILE"
echo "RemoteIpValve inserted into $FILE"
