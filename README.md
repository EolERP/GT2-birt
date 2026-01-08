# GT2-birt

What we use for local testing:
- http://localhost:8080/birt/frameset?xml_file=https%3A%2F%2Fgist.githubusercontent.com%2Fdpodhola-eolerp%2F16266ad29c3bc8309c6601e2c15ac3d8%2Fraw%2F4612297f7613d063ce2d0cf64e2f554ef6b03d7b%2Fdata.xml&__format=pdf&__report=credix_repayment_schedule.rptdesign

`docker builder prune`

`az login`

`az acr login --name ekorent`

`docker build --tag=birt .`

`docker run -d -p 8080:8080 birt`

`docker rmi ekorent.azurecr.io/birt:0.0.2`

`docker tag birt ekorent.azurecr.io/birt:0.0.2`

`docker push ekorent.azurecr.io/birt:0.0.2`

## E2E verification

### Smoke test for CRX-10 (JSESSIONID Secure behind reverse proxy)

To verify Tomcat treats the request as secure when behind a reverse proxy and sets the Secure flag on JSESSIONID:

1) Build and run the container locally
```
docker build -t birt .
docker run --rm -d --name birt -p 8080:8080 birt
```

2) Make a request with reverse-proxy headers
```
curl -i -H 'X-Forwarded-Proto: https' -H 'X-Forwarded-Port: 443' http://localhost:8080/birt/
```

3) Verify response headers contain Secure on JSESSIONID
- Look for a header like: `Set-Cookie: JSESSIONID=...; Path=/birt; HttpOnly; Secure`

If Secure is not present even with the headers, consider adding proxy attributes on the HTTP Connector in /etc/tomcat/server.xml:
```
<Connector port="8080" protocol="org.apache.coyote.http11.Http11NioProtocol"
           proxyPort="443" scheme="https" secure="true" />
```
Note: Keep TLS termination at the ingress; do not enable TLS directly in Tomcat.


One-shot end-to-end verification (build image, run container, auto-detect endpoint, fetch report, verify content):

```
./scripts/verify_version_report.sh
```

Environment overrides (optional):
- IMAGE_NAME (default: birt-e2e)
- CONTAINER_NAME (default: birt-e2e-test)
- HOST_PORT (default: 8080)
- BASE_URL (default: http://localhost:${HOST_PORT})
- REPORT_PATH (default: autodetect among /birt|/viewer|/birt-viewer with frameset/run)
- REPORT_FORMAT (default: html; also supports pdf)
- TIMEOUT_SEC (default: 120)
- REPORT_FILE (default: version.rptdesign)
- EXPECTED_FILE (default: version.txt)
- REPORT_DIR (default: autodetection in container)

Examples:
- Use a different port: `HOST_PORT=52383 ./scripts/verify_version_report.sh`
- Verify PDF output: `REPORT_FORMAT=pdf ./scripts/verify_version_report.sh`
- Skip autodetection with explicit path: `REPORT_PATH=/birt/run ./scripts/verify_version_report.sh`

Notes:
- The existing Dockerfile is used as-is; no changes required. It already places BIRT at /opt/tomcat/webapps/birt and copies version.rptdesign/version.txt there. The script will still auto-detect and copy these files into the running container if needed.



## Debug tips
- Print servlet mappings (inside container):
  docker exec -it ${CONTAINER_NAME:-birt-e2e-test} sh -lc "awk '/<servlet-mapping>/{f=1} f; /<\/servlet-mapping>/{print; f=0}' /opt/tomcat/webapps/birt/WEB-INF/web.xml"

- List JSP/HTML under the webapp:
  docker exec -it ${CONTAINER_NAME:-birt-e2e-test} sh -lc "find /opt/tomcat/webapps/birt -maxdepth 3 -type f \(-name '*.jsp' -o -name '*.html' -o -name '*.do'\) | sort"

- Show Tomcat logs:
  docker logs --tail 200 ${CONTAINER_NAME:-birt-e2e-test}

- Force endpoint or report dir if you already know them:
  REPORT_PATH=/birt/run ./scripts/verify_version_report.sh
  REPORT_DIR=/opt/tomcat/webapps/birt ./scripts/verify_version_report.sh

## ODA XML E2E test
The verification script also performs an optional ODA XML datasource end-to-end check.
- Test inputs: oda_xml_test.xml and oda_xml_test.rptdesign (bundled in repo). The report reads the XML and prints the value.
- Env overrides:
  - SKIP_ODA_XML_TEST=1 to skip the XML test
  - ODA_XML_EXPECTED (default: ODA_XML_OK)
  - ODA_XML_REPORT (default: oda_xml_test.rptdesign)
  - ODA_XML_DATA (default: oda_xml_test.xml)
  - ODA_XML_JAR_URL to override the XML ODA plugin JAR URL used in the test

## CI
A GitHub Action runs the end-to-end verification on PRs and main pushes.
- It fails the job if the script returns a non-zero exit code
- On failure it uploads e2e.log and docker logs as artifacts
- See .github/workflows/birt-e2e.yml

