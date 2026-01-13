ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

# --- Version / constants (keep everything else the same) ---

ARG JAVA_VERSION=21

ARG TOMCAT_VERSION=9.0.113
ARG TOMCAT_MAJOR=9

ARG BIRT_VERSION=4.22.0
ARG BIRT_BUILD=202512100727
ARG BIRT_CHANNEL=release
ENV BIRT_BASE_URL=https://download.eclipse.org/birt/updates/${BIRT_CHANNEL}/${BIRT_VERSION}/downloads

ENV TOMCAT_HOME=/opt/tomcat

# Pre-Installation and system packages
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

RUN grep -rl --include \*.xml allow . | xargs sed -i 's/allow/deny/g'

RUN wget -q "${BIRT_BASE_URL}/birt-runtime-${BIRT_VERSION}-${BIRT_BUILD}.zip" -P ${TOMCAT_HOME}/webapps \
    && wget -q "${BIRT_BASE_URL}/birt-runtime-${BIRT_VERSION}-${BIRT_BUILD}.zip.sha512" -O ${TOMCAT_HOME}/webapps/birt-runtime-${BIRT_VERSION}-${BIRT_BUILD}.zip.sha512 \
    && cd ${TOMCAT_HOME}/webapps && sha512sum -c "birt-runtime-${BIRT_VERSION}-${BIRT_BUILD}.zip.sha512"
RUN unzip "${TOMCAT_HOME}/webapps/birt-runtime-${BIRT_VERSION}-${BIRT_BUILD}.zip" -d ${TOMCAT_HOME}/webapps/birt-runtime
RUN mv "${TOMCAT_HOME}/webapps/birt-runtime/WebViewerExample" "${TOMCAT_HOME}/webapps/birt"
# Copy ODA XML driver provided by BIRT runtime into the webapp lib (prefer shipped jar)
RUN cp ${TOMCAT_HOME}/webapps/birt-runtime/ReportEngine/addons/org.eclipse.datatools.enablement.oda.xml_*.jar ${TOMCAT_HOME}/webapps/birt/WEB-INF/lib/ || true
# Fallback: if ODA XML jar is not present in runtime addons, fetch from Eclipse DTP 1.16.3 update site
RUN if ! ls ${TOMCAT_HOME}/webapps/birt/WEB-INF/lib/org.eclipse.datatools.enablement.oda.xml_*.jar >/dev/null 2>&1; then \
      echo "ODA XML driver missing in runtime; fetching from DTP update site" && \
      DTP_PLUGINS_INDEX_URL="https://download.eclipse.org/datatools/updates/release/1.16.3/plugins/" && \
      FILE=$(wget -qO- "$DTP_PLUGINS_INDEX_URL" | grep -o 'org.eclipse.datatools.enablement.oda.xml_[^"]*\.jar' | head -n1) && \
      wget -q "https://www.eclipse.org/downloads/download.php?file=/datatools/updates/release/1.16.3/plugins/$FILE" -O "/tmp/$FILE" && \
      cp "/tmp/$FILE" "${TOMCAT_HOME}/webapps/birt/WEB-INF/lib/"; \
    fi
RUN rm ${TOMCAT_HOME}/webapps/birt-runtime-${BIRT_VERSION}-${BIRT_BUILD}.zip
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
    && /usr/local/bin/patch_server_xml.sh /etc/tomcat/server.xml

# Map Reports folder
VOLUME ${TOMCAT_HOME}/webapps/birt

ADD mundial.ttf /usr/share/fonts/truetype
ADD arial.ttf /usr/share/fonts/truetype

ADD version.rptdesign ${TOMCAT_HOME}/webapps/birt
ADD version.txt ${TOMCAT_HOME}/webapps/birt
ADD index.html ${TOMCAT_HOME}/webapps/birt
ADD credix_repayment_schedule.rptdesign ${TOMCAT_HOME}/webapps/birt

# remove default pages with dangerous information
RUN rm -f -r ${TOMCAT_HOME}/webapps/ROOT/index.jsp
ADD error.html ${TOMCAT_HOME}/webapps/ROOT
COPY web.xml ${TOMCAT_HOME}/webapps/ROOT/WEB-INF

ADD /cert/*.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates

RUN rm ${TOMCAT_HOME}/conf/logging.properties

# Modify BIRT viewer settings for reports path issues
# 1) Set it in WEB-INF/web.xml (robust whitespace-insensitive)
RUN perl -0777 -i -pe 's|(\<param-name\>\s*BIRT_VIEWER_WORKING_FOLDER\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1/opt/tomcat/webapps/birt/\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml || true
# 2) Also set it explicitly in WEB-INF/web-viewer.xml (newer packs read from here)
RUN perl -0777 -i -pe 's|(\<param-name\>\s*BIRT_VIEWER_WORKING_FOLDER\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1/opt/tomcat/webapps/birt/\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml || true
# Relax working folder access (some Tomcat 9.0.11x + BIRT combos require it)
RUN perl -0777 -i -pe 's|(\<param-name\>\s*WORKING_FOLDER_ACCESS_ONLY\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1false\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml || true
RUN perl -0777 -i -pe 's|(\<param-name\>\s*WORKING_FOLDER_ACCESS_ONLY\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1false\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml || true

# Start
CMD ["/opt/tomcat/bin/catalina.sh", "run"]

# Port
EXPOSE 8080