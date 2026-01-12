ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

# --- Version / constants (keep everything else the same) ---
ARG JAVA_VERSION=21

ARG TOMCAT_VERSION=9.0.113
ARG TOMCAT_MAJOR=9

ARG BIRT_VERSION=4.22.0
ARG BIRT_BUILD=202512100727
ARG BIRT_CHANNEL=release
# BIRT base URL will be derived from channel during download (release | latest | milestone)
ARG ODA_XML_JAR_URL=https://download.eclipse.org/releases/2021-03/202103171000/plugins/org.eclipse.datatools.enablement.oda.xml_1.4.102.201901091730.jar

ENV TOMCAT_HOME=/opt/tomcat

# Pre-Installation and system packages
# NOTE: install fontconfig + fonts explicitly, otherwise PDF renderer may lose glyphs (Č -> nothing).
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        openjdk-${JAVA_VERSION}-jre-headless \
        wget \
        unzip \
        fontconfig \
        libfreetype6 \
        fonts-dejavu-core \
        fonts-liberation \
        perl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Tomcat
RUN wget "https://archive.apache.org/dist/tomcat/tomcat-${TOMCAT_MAJOR}/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz" -P ${TOMCAT_HOME}
RUN tar xzvf ${TOMCAT_HOME}/apache-tomcat-${TOMCAT_VERSION}.tar.gz -C ${TOMCAT_HOME} --strip-components=1
RUN rm ${TOMCAT_HOME}/apache-tomcat-${TOMCAT_VERSION}.tar.gz

# Harden: flip allow -> deny in any XML (as you had it)
RUN grep -rl --include \*.xml allow . | xargs sed -i 's/allow/deny/g'

# Determine BIRT base URL based on channel and download runtime
SHELL ["/bin/bash", "-c"]
RUN set -euo pipefail; \
    if [[ "${BIRT_CHANNEL}" == "latest" ]]; then \
      BIRT_BASE_URL="https://download.eclipse.org/birt/updates/release/latest/downloads"; \
    elif [[ "${BIRT_CHANNEL}" == "milestone" ]]; then \
      BIRT_BASE_URL="https://download.eclipse.org/birt/updates/milestone/${BIRT_VERSION}/downloads"; \
    else \
      BIRT_BASE_URL="https://download.eclipse.org/birt/updates/release/${BIRT_VERSION}/downloads"; \
    fi; \
    echo "Using BIRT_BASE_URL=${BIRT_BASE_URL}"; \
    RUNTIME_ZIP="birt-runtime-${BIRT_VERSION}-${BIRT_BUILD}.zip"; \
    wget "${BIRT_BASE_URL}/${RUNTIME_ZIP}" -P ${TOMCAT_HOME}/webapps; \
    if wget -qO- --spider "${BIRT_BASE_URL}/${RUNTIME_ZIP}.sha512"; then \
      wget "${BIRT_BASE_URL}/${RUNTIME_ZIP}.sha512" -P ${TOMCAT_HOME}/webapps; \
      cd ${TOMCAT_HOME}/webapps; \
      sha512sum -c "${RUNTIME_ZIP}.sha512"; \
    fi; \
    unzip "${TOMCAT_HOME}/webapps/${RUNTIME_ZIP}" -d ${TOMCAT_HOME}/webapps/birt-runtime; \
    mv "${TOMCAT_HOME}/webapps/birt-runtime/WebViewerExample" "${TOMCAT_HOME}/webapps/birt"; \
    if compgen -G "${TOMCAT_HOME}/webapps/birt-runtime/ReportEngine/addons/org.eclipse.datatools.enablement.oda.xml_*.jar" > /dev/null; then \
      cp ${TOMCAT_HOME}/webapps/birt-runtime/ReportEngine/addons/org.eclipse.datatools.enablement.oda.xml_*.jar ${TOMCAT_HOME}/webapps/birt/WEB-INF/lib/; \
    else \
      wget -O ${TOMCAT_HOME}/webapps/birt/WEB-INF/lib/$(basename ${ODA_XML_JAR_URL}) "${ODA_XML_JAR_URL}" || echo "WARN: ODA XML fallback unavailable (non-fatal)"; \
    fi; \
    rm -f ${TOMCAT_HOME}/webapps/${RUNTIME_ZIP}*; \
    rm -rf ${TOMCAT_HOME}/webapps/birt-runtime

# Prepare Tomcat configuration in /etc/tomcat and symlink conf
RUN mkdir -p /etc/tomcat \
    && cp -a ${TOMCAT_HOME}/conf/. /etc/tomcat/ \
    && rm -rf ${TOMCAT_HOME}/conf \
    && ln -s /etc/tomcat ${TOMCAT_HOME}/conf

# Patch server.xml idempotently to respect reverse proxy headers
COPY scripts/patch_server_xml.sh /usr/local/bin/patch_server_xml.sh
RUN chmod +x /usr/local/bin/patch_server_xml.sh \
    && /usr/local/bin/patch_server_xml.sh /etc/tomcat/server.xml

# Map Reports folder
VOLUME ${TOMCAT_HOME}/webapps/birt

# Add your fonts (as before)
ADD mundial.ttf /usr/share/fonts/truetype
ADD arial.ttf /usr/share/fonts/truetype

# Refresh font cache
RUN fc-cache -f -v

# ---- CRITICAL: Make BIRT PDF engine actually SEE the fonts ----
# Robust: locate fontsConfig.xml via find (BIRT plugin names/layout may change by version)
RUN set -euo pipefail; \
    PLUGINS_DIR="${TOMCAT_HOME}/webapps/birt/WEB-INF/platform/plugins"; \
    if [[ ! -d "${PLUGINS_DIR}" ]]; then \
      echo "ERROR: BIRT plugins directory not found: ${PLUGINS_DIR}"; \
      echo "Listing ${TOMCAT_HOME}/webapps/birt/WEB-INF:"; \
      ls -la "${TOMCAT_HOME}/webapps/birt/WEB-INF" || true; \
      exit 1; \
    fi; \
    \
    FC_XML="$(find "${PLUGINS_DIR}" -maxdepth 3 -type f -name 'fontsConfig.xml' | head -n1)"; \
    if [[ -z "${FC_XML}" ]]; then \
      echo "ERROR: fontsConfig.xml not found under ${PLUGINS_DIR}"; \
      echo "Available plugins (top level):"; \
      ls -1 "${PLUGINS_DIR}" | head -n 200 || true; \
      echo "Searching for anything font-related:"; \
      find "${PLUGINS_DIR}" -maxdepth 2 -type d -iname '*font*' -o -type f -iname '*font*' | head -n 200 || true; \
      exit 1; \
    fi; \
    \
    FONT_PLUGIN_DIR="$(dirname "${FC_XML}")"; \
    echo "BIRT fontsConfig.xml: ${FC_XML}"; \
    echo "BIRT font plugin dir: ${FONT_PLUGIN_DIR}"; \
    mkdir -p "${FONT_PLUGIN_DIR}/fonts"; \
    \
    # Copy your custom + common fonts into the plugin folder (so PDF engine can't ignore them)
    cp -f /usr/share/fonts/truetype/*.ttf "${FONT_PLUGIN_DIR}/fonts/" 2>/dev/null || true; \
    cp -f /usr/share/fonts/truetype/dejavu/*.ttf "${FONT_PLUGIN_DIR}/fonts/" 2>/dev/null || true; \
    cp -f /usr/share/fonts/truetype/liberation/*.ttf "${FONT_PLUGIN_DIR}/fonts/" 2>/dev/null || true; \
    \
    # 1) Ensure these font paths are present inside <font-paths> (idempotent)
    for P in "fonts" "/usr/share/fonts" "/usr/share/fonts/truetype" "/usr/share/fonts/truetype/dejavu" "/usr/share/fonts/truetype/liberation"; do \
      if ! grep -Fq "path=\"${P}\"" "${FC_XML}"; then \
        if grep -q "<font-paths>" "${FC_XML}"; then \
          perl -0777 -i -pe "s|<font-paths>|<font-paths>\\n    <path path=\\\"${P}\\\"/>|s" "${FC_XML}"; \
        else \
          perl -0777 -i -pe "s|(<configuration[^>]*>)|\\1\\n  <font-paths>\\n    <path path=\\\"${P}\\\"/>\\n  </font-paths>|s" "${FC_XML}"; \
        fi; \
      fi; \
    done; \
    \
    # 2) Add alias Arial -> DejaVu Sans (idempotent)
    if ! grep -Eq "<alias[^>]+name=\\\"Arial\\\"" "${FC_XML}"; then \
      if grep -q "<font-aliases>" "${FC_XML}"; then \
        perl -0777 -i -pe 's|<font-aliases>|<font-aliases>\n    <alias name="Arial" font="DejaVu Sans"/>\n    <alias name="Arial Unicode MS" font="DejaVu Sans"/>|s' "${FC_XML}"; \
      else \
        perl -0777 -i -pe 's|(</font-paths>)|$1\n  <font-aliases>\n    <alias name="Arial" font="DejaVu Sans"/>\n    <alias name="Arial Unicode MS" font="DejaVu Sans"/>\n  </font-aliases>|s' "${FC_XML}"; \
      fi; \
    fi; \
    \
    echo "Patched ${FC_XML} (showing font-paths and aliases):"; \
    grep -nE "font-paths|<path |font-aliases|<alias " "${FC_XML}" | head -n 200 || true

# App assets
ADD version.rptdesign ${TOMCAT_HOME}/webapps/birt
ADD version.txt ${TOMCAT_HOME}/webapps/birt
ADD index.html ${TOMCAT_HOME}/webapps/birt
ADD credix_repayment_schedule.rptdesign ${TOMCAT_HOME}/webapps/birt

# remove default pages with dangerous information
RUN rm -rf ${TOMCAT_HOME}/webapps/ROOT/index.jsp
ADD error.html ${TOMCAT_HOME}/webapps/ROOT
COPY web.xml ${TOMCAT_HOME}/webapps/ROOT/WEB-INF

ADD /cert/*.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates

RUN rm -f ${TOMCAT_HOME}/conf/logging.properties

# Modify BIRT viewer settings for reports path issues
RUN perl -0777 -i -pe 's|(\<param-name\>\s*BIRT_VIEWER_WORKING_FOLDER\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1/opt/tomcat/webapps/birt/\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml || true
RUN perl -0777 -i -pe 's|(\<param-name\>\s*BIRT_VIEWER_WORKING_FOLDER\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1/opt/tomcat/webapps/birt/\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml || true
RUN perl -0777 -i -pe 's|(\<param-name\>\s*WORKING_FOLDER_ACCESS_ONLY\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1false\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml || true
RUN perl -0777 -i -pe 's|(\<param-name\>\s*WORKING_FOLDER_ACCESS_ONLY\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1false\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml || true

# Start
CMD ["/opt/tomcat/bin/catalina.sh", "run"]

# Port
EXPOSE 8080
