#!/usr/bin/env bash
set -euo pipefail
IMAGE_TAG="gt2-birt:localtest"
CONTAINER_NAME="birt-local"
ART_DIR="artifacts"
mkdir -p "$ART_DIR"

echo "Building image..."
docker build -t "$IMAGE_TAG" .

echo "Running container..."
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
trap 'echo "Collecting logs..."; docker logs "$CONTAINER_NAME" > "$ART_DIR/docker.log" 2>&1 || true; docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true' EXIT

docker run -d --name "$CONTAINER_NAME" -p 8080:8080 \
  -v "$(pwd)/tests:/opt/tomcat/webapps/birt/tests:ro" \
  "$IMAGE_TAG"

bash tests/scripts/wait_for_http.sh "http://localhost:8080/birt/" 180

bash tests/scripts/find_birt_endpoint.sh > "$ART_DIR/viewer_base.txt"
VIEWER_BASE=$(cat "$ART_DIR/viewer_base.txt")

OUT_HTML="$ART_DIR/rendered.html"
if bash tests/scripts/render_report.sh "$VIEWER_BASE" "tests/reports/smoke.rptdesign" html "$OUT_HTML" preview; then
  :
elif bash tests/scripts/render_report.sh "$VIEWER_BASE" "tests/reports/smoke.rptdesign" html "$OUT_HTML" frameset; then
  :
elif bash tests/scripts/render_report.sh "$VIEWER_BASE" "tests/reports/smoke.rptdesign" html "$OUT_HTML" run; then
  :
else
  echo "Render failed" >&2
  exit 1
fi

bash tests/scripts/assert_render.sh "$OUT_HTML" "$ART_DIR/http_status.txt" "SMOKE_OK" "TOTAL=3"

echo "OK. Rendered -> $OUT_HTML"
