#!/bin/sh
set -eu

FILE="${1:-}"
if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "Usage: $0 /path/to/server.xml" >&2
  exit 2
fi

echo "==== server.xml context (lines 150-180) BEFORE patch ===="
nl -ba "$FILE" | sed -n '150,180p' || true

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# 1) Insert RemoteIpValve inside <Host> if missing
have_valve=0
if grep -q 'org\.apache\.catalina\.valves\.RemoteIpValve' "$FILE"; then
  have_valve=1
fi

valve='        <Valve className="org.apache.catalina.valves.RemoteIpValve"
               protocolHeader="x-forwarded-proto"
               protocolHeaderHttpsValue="https"
               portHeader="x-forwarded-port" />'

# 2) Ensure proxy-aware attributes on HTTP connector (8080) if missing
# We add scheme/secure/proxyPort only if they are not present on that Connector line.
# This is a conservative line-based patch that targets the default HTTP connector.
awk -v valve="$valve" -v have_valve="$have_valve" '
BEGIN { in_host=0; inserted=0 }

function patch_connector(line,    out) {
  out=line
  if (out ~ /port="8080"/) {
    if (out !~ /scheme="/)    out = gensub(/\/?>$/, " scheme=\"https\"&", 1, out)
    if (out !~ /secure="/)    out = gensub(/\/?>$/, " secure=\"true\"&", 1, out)
    if (out !~ /proxyPort="/) out = gensub(/\/?>$/, " proxyPort=\"443\"&", 1, out)
  }
  return out
}

{
  # Patch Connector lines (default HTTP connector)
  if ($0 ~ /<Connector[[:space:]]/ && $0 ~ /port="8080"/) {
    # Use gawk-compatible gensub. If gensub not available, fallback below.
    # We detect absence at runtime by checking if "gensub" works is not possible in awk,
    # so we structure the Docker environment to use gawk? Not guaranteed.
  }

  print
}
' "$FILE" > "$tmp" 2>/dev/null || true

# The above awk uses gensub (gawk). Ubuntu's /usr/bin/awk is usually mawk, without gensub.
# So we do connector patching with sed instead (POSIX-safe), and keep awk for Host/Valve insertion.

# First: connector patch via sed (idempotent)
cp "$FILE" "${FILE}.bak"
sed -i \
  -e '/<Connector[^>]*port="8080"/{
        /scheme="/! s/<Connector/<Connector scheme="https"/
        /secure="/! s/<Connector/<Connector secure="true"/
        /proxyPort="/! s/<Connector/<Connector proxyPort="443"/
      }' \
  "$FILE"

# Second: insert RemoteIpValve if missing (idempotent)
if [ "$have_valve" -eq 0 ]; then
  tmp2="$(mktemp)"
  trap 'rm -f "$tmp" "$tmp2"' EXIT

  awk -v valve="$valve" '
  BEGIN { in_host=0; inserted=0 }
  $0 ~ /<Host[[:space:]]/ { in_host=1 }
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
  }' "$FILE" > "$tmp2"

  cat "$tmp2" > "$FILE"
  echo "Inserted RemoteIpValve into $FILE"
else
  echo "RemoteIpValve already present; nothing to do."
fi

echo "Patched connector (scheme/secure/proxyPort) in $FILE"
