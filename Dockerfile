# --- build stage: tiny filter that sets an arbitrary response header (Tomcat 9 / javax.*) ---
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

RUN javac -cp /tmp/servlet-api.jar org/apache/catalina/filters/ResponseHeaderFilter.java \
 && jar cf response-header-filter.jar org/apache/catalina/filters/ResponseHeaderFilter.class


# --------------------------------------------------------------------
# main image
# --------------------------------------------------------------------
ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ARG JAVA_VERSION=17
ARG TOMCAT_VERSION=9.0.113
ARG TOMCAT_MAJOR=9

ARG BIRT_VERSION=4.19.0
ARG BIRT_DROP=R-R1-4.13.0-202303022006
ARG BIRT_RUNTIME_DATE=202503120947

ENV TOMCAT_HOME=/opt/tomcat

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
# CSP: set globally via Tomcat ResponseHeaderFilter (NO RewriteValve)
# ----------------------------------------------------------
RUN set -eux; \
    export CSP="default-src 'self'; base-uri 'self'; object-src 'none'; frame-ancestors 'self'; form-action 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: https://eclipse-birt.github.io; font-src 'self' data:; connect-src 'self'; frame-src 'self'; worker-src 'self' blob:; upgrade-insecure-requests"; \
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
