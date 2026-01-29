ARG UBUNTU_VERSION=24.04

# --- build stage: tiny filters (Tomcat 9 / javax.*) ---
FROM eclipse-temurin:17-jdk AS cspfilter-build
WORKDIR /src

ADD https://repo1.maven.org/maven2/javax/servlet/javax.servlet-api/4.0.1/javax.servlet-api-4.0.1.jar /tmp/servlet-api.jar

RUN mkdir -p org/apache/catalina/filters && cat > org/apache/catalina/filters/ResponseHeaderFilter.java <<'EOF'
package org.apache.catalina.filters;

import javax.servlet.*;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;

public class ResponseHeaderFilter implements Filter {
    private String headerName;
    private String headerValue;

    @Override
    public void init(FilterConfig filterConfig) {
        headerName = filterConfig.getInitParameter("headerName");
        headerValue = filterConfig.getInitParameter("headerValue");
        if (headerName == null || headerName.isEmpty()) headerName = "Content-Security-Policy";
        if (headerValue == null) headerValue = "";
    }

    @Override
    public void doFilter(ServletRequest request, ServletResponse response, FilterChain chain)
            throws IOException, ServletException {
        if (response instanceof HttpServletResponse) {
            ((HttpServletResponse) response).setHeader(headerName, headerValue);
        }
        chain.doFilter(request, response);
    }

    @Override
    public void destroy() {}
}
EOF

# RequestGuardFilter: validates xml_file param for /birt/frameset and /birt/run
RUN cat > org/apache/catalina/filters/RequestGuardFilter.java <<'EOF'
package org.apache.catalina.filters;

import javax.servlet.*;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.net.URL;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;

public class RequestGuardFilter implements Filter {
    private static final int MAX_LEN = 2000;

    @Override
    public void init(FilterConfig filterConfig) {}

    @Override
    public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
            throws IOException, ServletException {
        if (!(req instanceof HttpServletRequest) || !(res instanceof HttpServletResponse)) {
            chain.doFilter(req, res);
            return;
        }
        HttpServletRequest request = (HttpServletRequest) req;
        HttpServletResponse response = (HttpServletResponse) res;

        String xml = request.getParameter("xml_file");
        if (xml == null || xml.isEmpty()) {
            chain.doFilter(req, res);
            return;
        }

        String decoded = safeDecode(xml);
        if (decoded == null) {
            reject(response, "decoding failed");
            return;
        }
        if (decoded.contains("%25")) {
            String d2 = safeDecode(decoded);
            if (d2 != null) decoded = d2; else {
                reject(response, "decoding failed (double-encoding)");
                return;
            }
        }

        if (decoded.length() > MAX_LEN) {
            reject(response, "value too long");
            return;
        }

        try {
            URL u = new URL(decoded);
            String proto = u.getProtocol();
            if (!("http".equalsIgnoreCase(proto) || "https".equalsIgnoreCase(proto))) {
                reject(response, "unsupported URL scheme");
                return;
            }
        } catch (Exception e) {
            reject(response, "not a valid URL after decoding");
            return;
        }

        chain.doFilter(req, res);
    }

    private static String safeDecode(String s) {
        try {
            return URLDecoder.decode(s, StandardCharsets.UTF_8.name());
        } catch (Exception e) {
            return null;
        }
    }

    private static void reject(HttpServletResponse response, String reason) throws IOException {
        boolean debug = "1".equals(System.getenv().getOrDefault("SHOW_DEBUG", "0"));
        response.setStatus(HttpServletResponse.SC_BAD_REQUEST);
        response.setContentType("text/plain; charset=utf-8");
        String msg = debug ? ("Invalid xml_file parameter: " + reason) : "Invalid request. Input rejected.";
        byte[] bytes = msg.getBytes(StandardCharsets.UTF_8);
        response.setContentLength(bytes.length);
        response.getOutputStream().write(bytes);
    }
}
EOF

# BirtResponseSanitizerFilter: wraps response to sanitize verbose BIRT errors when not in debug mode
RUN cat > org/apache/catalina/filters/BirtResponseSanitizerFilter.java <<'EOF'
package org.apache.catalina.filters;

import javax.servlet.*;
import javax.servlet.http.*;
import java.io.*;
import java.nio.charset.StandardCharsets;

public class BirtResponseSanitizerFilter implements Filter {
    private static final byte[] PDF_MAGIC = "%PDF-".getBytes(StandardCharsets.US_ASCII);
    private static final String GENERIC = "Invalid request. Input rejected.";

    @Override
    public void init(FilterConfig filterConfig) {}

    @Override
    public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
            throws IOException, ServletException {
        if (!(req instanceof HttpServletRequest) || !(res instanceof HttpServletResponse)) {
            chain.doFilter(req, res);
            return;
        }
        HttpServletResponse raw = (HttpServletResponse) res;
        BufferingResponseWrapper wrapper = new BufferingResponseWrapper(raw);
        chain.doFilter(req, wrapper);

        // If committed (despite our buffering), do nothing
        if (raw.isCommitted()) return;

        boolean debug = "1".equals(System.getenv().getOrDefault("SHOW_DEBUG", "0"));
        byte[] body = wrapper.getBody();
        String ct = raw.getContentType();
        int status = raw.getStatus();

        if (debug) {
            // Pass-through original captured body
            writeBody(raw, body, ct);
            return;
        }

        // Do not sanitize valid PDFs
        if (isPdf(ct, body)) {
            writeBody(raw, body, ct);
            return;
        }

        // Only sanitize text-like responses
        boolean textLike = isTextLike(ct, body);
        if (!textLike) {
            writeBody(raw, body, ct);
            return;
        }

        // Leak detection heuristics
        String s = new String(body, StandardCharsets.UTF_8);
        String sl = s.toLowerCase();
        boolean leak = s.contains("Exception")
                || sl.contains("stacktrace")
                || s.contains("\nat ")
                || sl.contains("org.eclipse.birt")
                || sl.contains("java.lang.")
                || sl.contains("javax.servlet")
                || sl.contains("<html");

        if (leak) {
            int outStatus = (status >= 500) ? status : 400;
            raw.resetBuffer();
            raw.setStatus(outStatus);
            raw.setHeader("Cache-Control", "no-store");
            raw.setContentType("text/plain; charset=utf-8");
            byte[] msg = GENERIC.getBytes(StandardCharsets.UTF_8);
            raw.setContentLength(msg.length);
            raw.getOutputStream().write(msg);
        } else {
            writeBody(raw, body, ct);
        }
    }

    @Override
    public void destroy() {}

    private static boolean isPdf(String ct, byte[] body) {
        if (ct != null && ct.toLowerCase().startsWith("application/pdf")) {
            if (body != null && body.length >= 5) {
                for (int i = 0; i < PDF_MAGIC.length; i++) {
                    if (body[i] != PDF_MAGIC[i]) return false;
                }
                return true;
            }
        }
        return false;
    }

    private static boolean isTextLike(String ct, byte[] body) {
        if (ct != null) {
            String l = ct.toLowerCase();
            if (l.startsWith("text/") || l.contains("html")) return true;
        }
        // If no content-type, heuristically decide based on content
        if (body == null || body.length == 0) return false;
        byte b0 = body[0];
        if (b0 == '<') return true;
        // Basic printable ASCII ratio check (best-effort)
        int printable = 0;
        int n = Math.min(body.length, 200);
        for (int i = 0; i < n; i++) {
            int c = body[i] & 0xff;
            if (c == 9 || c == 10 || c == 13 || (c >= 32 && c <= 126)) printable++;
        }
        return printable >= n * 0.6;
    }

    private static void writeBody(HttpServletResponse res, byte[] body, String ct) throws IOException {
        if (ct != null && !ct.isEmpty()) {
            res.setContentType(ct);
        }
        if (body != null && body.length > 0) {
            res.setContentLength(body.length);
            res.getOutputStream().write(body);
        } else {
            res.setContentLength(0);
        }
    }

    private static class BufferingResponseWrapper extends HttpServletResponseWrapper {
        private final ByteArrayOutputStream buffer = new ByteArrayOutputStream(4096);
        private ServletOutputStream outputStream;
        private PrintWriter writer;

        BufferingResponseWrapper(HttpServletResponse response) {
            super(response);
        }

        @Override
        public ServletOutputStream getOutputStream() {
            if (writer != null) throw new IllegalStateException("getWriter() already called");
            if (outputStream == null) {
                outputStream = new ServletOutputStream() {
                    @Override public boolean isReady() { return true; }
                    @Override public void setWriteListener(WriteListener writeListener) {}
                    @Override public void write(int b) { buffer.write(b); }
                    @Override public void write(byte[] b, int off, int len) { buffer.write(b, off, len); }
                    @Override public void flush() {}
                };
            }
            return outputStream;
        }

        @Override
        public PrintWriter getWriter() {
            if (outputStream != null) throw new IllegalStateException("getOutputStream() already called");
            if (writer == null) {
                writer = new PrintWriter(new OutputStreamWriter(buffer, StandardCharsets.UTF_8));
            }
            return writer;
        }

        @Override
        public void flushBuffer() {
            // do not commit underlying response early
            if (writer != null) writer.flush();
        }

        @Override
        public void reset() { buffer.reset(); }

        @Override
        public void resetBuffer() { buffer.reset(); }

        byte[] getBody() throws IOException {
            if (writer != null) writer.flush();
            return buffer.toByteArray();
        }
    }
}
EOF

RUN javac -cp /tmp/servlet-api.jar org/apache/catalina/filters/ResponseHeaderFilter.java org/apache/catalina/filters/RequestGuardFilter.java org/apache/catalina/filters/BirtResponseSanitizerFilter.java \
 && jar cf response-header-filter.jar org/apache/catalina/filters/*.class


# --------------------------------------------------------------------
# main image
# --------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION}

ARG JAVA_VERSION=17
ARG TOMCAT_VERSION=9.0.113
ARG TOMCAT_MAJOR=9

ARG BIRT_VERSION=4.19.0
ARG BIRT_DROP=R-R1-4.13.0-202303022006
ARG BIRT_RUNTIME_DATE=202503120947

ENV TOMCAT_HOME=/opt/tomcat
ENV SHOW_DEBUG=0

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        perl \
        openjdk-${JAVA_VERSION}-jre-headless \
        fontconfig \
        wget \
        unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN wget "https://archive.apache.org/dist/tomcat/tomcat-${TOMCAT_MAJOR}/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz" -P ${TOMCAT_HOME}
RUN tar xzvf ${TOMCAT_HOME}/apache-tomcat-${TOMCAT_VERSION}.tar.gz -C ${TOMCAT_HOME} --strip-components=1
RUN rm ${TOMCAT_HOME}/apache-tomcat-${TOMCAT_VERSION}.tar.gz

# Tomcat does NOT provide this class; we add our own jar to satisfy the configured filter.
COPY --from=cspfilter-build /src/response-header-filter.jar /opt/tomcat/lib/response-header-filter.jar

RUN grep -rl --include \*.xml allow . | xargs sed -i 's/allow/deny/g'

RUN wget "https://download.eclipse.org/birt/updates/release/${BIRT_VERSION}/downloads/birt-runtime-${BIRT_VERSION}-${BIRT_RUNTIME_DATE}.zip" -P ${TOMCAT_HOME}/webapps
RUN unzip "${TOMCAT_HOME}/webapps/birt-runtime-${BIRT_VERSION}-${BIRT_RUNTIME_DATE}.zip" -d ${TOMCAT_HOME}/webapps/birt-runtime
RUN mv "${TOMCAT_HOME}/webapps/birt-runtime/WebViewerExample" "${TOMCAT_HOME}/webapps/birt"
RUN cp ${TOMCAT_HOME}/webapps/birt-runtime/ReportEngine/addons/org.eclipse.datatools.enablement.oda.xml_*.jar ${TOMCAT_HOME}/webapps/birt/WEB-INF/lib/
RUN rm ${TOMCAT_HOME}/webapps/birt-runtime-${BIRT_VERSION}-${BIRT_RUNTIME_DATE}.zip
RUN rm -f -r ${TOMCAT_HOME}/webapps/birt-runtime

# ----------------------------------------------------------
# Inject RequestGuardFilter and BirtResponseSanitizerFilter into BIRT web.xml (idempotent)
# ----------------------------------------------------------
RUN set -eux; \
    BWXML="${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml"; \
    # cleanup any previous blocks (idempotent)
    perl -0777 -i -pe 's|\s*<filter>\s*<filter-name>RequestGuardFilter</filter-name>.*?</filter>\s*||smg' "$BWXML"; \
    perl -0777 -i -pe 's|\s*<filter-mapping>\s*<filter-name>RequestGuardFilter</filter-name>.*?</filter-mapping>\s*||smg' "$BWXML"; \
    perl -0777 -i -pe 's|\s*<filter>\s*<filter-name>BirtResponseSanitizerFilter</filter-name>.*?</filter>\s*||smg' "$BWXML"; \
    perl -0777 -i -pe 's|\s*<filter-mapping>\s*<filter-name>BirtResponseSanitizerFilter</filter-name>.*?</filter-mapping>\s*||smg' "$BWXML"; \
    # insert filters + mappings before </web-app> (sanitizer first to wrap output early)
    perl -0777 -i -pe "s|</web-app>|  <filter>\n    <filter-name>BirtResponseSanitizerFilter</filter-name>\n    <filter-class>org.apache.catalina.filters.BirtResponseSanitizerFilter</filter-class>\n  </filter>\n  <filter>\n    <filter-name>RequestGuardFilter</filter-name>\n    <filter-class>org.apache.catalina.filters.RequestGuardFilter</filter-class>\n  </filter>\n\n  <filter-mapping>\n    <filter-name>BirtResponseSanitizerFilter</filter-name>\n    <url-pattern>/frameset</url-pattern>\n  </filter-mapping>\n  <filter-mapping>\n    <filter-name>BirtResponseSanitizerFilter</filter-name>\n    <url-pattern>/run</url-pattern>\n  </filter-mapping>\n  <filter-mapping>\n    <filter-name>RequestGuardFilter</filter-name>\n    <url-pattern>/frameset</url-pattern>\n  </filter-mapping>\n  <filter-mapping>\n    <filter-name>RequestGuardFilter</filter-name>\n    <url-pattern>/run</url-pattern>\n  </filter-mapping>\n</web-app>|smg" "$BWXML"; \
    echo "=== injected Sanitizer + RequestGuard filters in BIRT web.xml ==="; \
    grep -n "BirtResponseSanitizerFilter\|RequestGuardFilter" -n "$BWXML" || true

# ----------------------------------------------------------
# Tomcat conf into /etc/tomcat + patch server.xml (Secure cookies)
# ----------------------------------------------------------
RUN mkdir -p /etc/tomcat \
    && cp -a ${TOMCAT_HOME}/conf/. /etc/tomcat/ \
    && rm -rf ${TOMCAT_HOME}/conf \
    && ln -s /etc/tomcat ${TOMCAT_HOME}/conf

COPY scripts/patch_server_xml.sh /usr/local/bin/patch_server_xml.sh
RUN chmod +x /usr/local/bin/patch_server_xml.sh \
    && /usr/local/bin/patch_server_xml.sh /opt/tomcat/conf/server.xml

VOLUME ${TOMCAT_HOME}/webapps/birt

ADD mundial.ttf /usr/share/fonts/truetype
ADD arial.ttf /usr/share/fonts/truetype

ADD version.rptdesign ${TOMCAT_HOME}/webapps/birt
ADD version.txt ${TOMCAT_HOME}/webapps/birt
ADD index.html ${TOMCAT_HOME}/webapps/birt
ADD credix_repayment_schedule.rptdesign ${TOMCAT_HOME}/webapps/birt

RUN rm -f -r ${TOMCAT_HOME}/webapps/ROOT/index.jsp
ADD error.html ${TOMCAT_HOME}/webapps/ROOT
COPY web.xml ${TOMCAT_HOME}/webapps/ROOT/WEB-INF

ADD /cert/*.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates

# ----------------------------------------------------------
# CSP: PDF-only strict mode (global header)
# NOTE: frame-ancestors 'none' is the strictest. If you embed PDFs in your own UI, change to 'self'.
# ----------------------------------------------------------
RUN set -eux; \
    export CSP="default-src 'none'; base-uri 'none'; object-src 'none'; frame-ancestors 'none'; form-action 'none'; script-src 'none'; style-src 'none'; img-src 'none'; font-src 'none'; connect-src 'none'; media-src 'none'; frame-src 'none'; worker-src 'none'; manifest-src 'none'; prefetch-src 'none'; upgrade-insecure-requests; block-all-mixed-content"; \
    WEBXML="/opt/tomcat/conf/web.xml"; \
    # remove any previous CSP filter block (idempotent cleanup)
    perl -0777 -i -pe 's|\s*<filter>\s*<filter-name>CSPResponseHeaderFilter</filter-name>.*?</filter>\s*||smg' "$WEBXML"; \
    perl -0777 -i -pe 's|\s*<filter-mapping>\s*<filter-name>CSPResponseHeaderFilter</filter-name>.*?</filter-mapping>\s*||smg' "$WEBXML"; \
    # insert filter + mapping before </web-app>
    perl -0777 -i -pe "s|</web-app>|  <filter>\\n    <filter-name>CSPResponseHeaderFilter</filter-name>\\n    <filter-class>org.apache.catalina.filters.ResponseHeaderFilter</filter-class>\\n    <init-param>\\n      <param-name>headerName</param-name>\\n      <param-value>Content-Security-Policy</param-value>\\n    </init-param>\\n    <init-param>\\n      <param-name>headerValue</param-name>\\n      <param-value>\$ENV{CSP}</param-value>\\n    </init-param>\\n  </filter>\\n\\n  <filter-mapping>\\n    <filter-name>CSPResponseHeaderFilter</filter-name>\\n    <url-pattern>/*</url-pattern>\\n  </filter-mapping>\\n</web-app>|smg" "$WEBXML"; \
    # show proof in build logs
    echo "=== injected CSP filter in conf/web.xml ==="; \
    grep -n "CSPResponseHeaderFilter" -n "$WEBXML" || true; \
    grep -n "Content-Security-Policy" -n "$WEBXML" || true

RUN rm ${TOMCAT_HOME}/conf/logging.properties

RUN perl -0777 -i -pe 's|(\<param-name\>\s*BIRT_VIEWER_WORKING_FOLDER\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1/opt/tomcat/webapps/birt/\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml || true
RUN perl -0777 -i -pe 's|(\<param-name\>\s*BIRT_VIEWER_WORKING_FOLDER\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1/opt/tomcat/webapps/birt/\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml || true
RUN perl -0777 -i -pe 's|(\<param-name\>\s*WORKING_FOLDER_ACCESS_ONLY\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1false\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml || true
RUN perl -0777 -i -pe 's|(\<param-name\>\s*WORKING_FOLDER_ACCESS_ONLY\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1false\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml || true

CMD ["/opt/tomcat/bin/catalina.sh", "run"]
EXPOSE 8080
