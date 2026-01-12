ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

# --- Version / constants ---
ARG JAVA_VERSION=21

ARG TOMCAT_VERSION=9.0.113
ARG TOMCAT_MAJOR=9

ARG BIRT_VERSION=4.22.0
ARG BIRT_BUILD=202512100727
ARG BIRT_CHANNEL=release

ARG ODA_XML_JAR_URL=https://download.eclipse.org/releases/2021-03/202103171000/plugins/org.eclipse.datatools.enablement.oda.xml_1.4.102.201901091730.jar

ENV TOMCAT_HOME=/opt/tomcat
ENV BIRT_FONTS_DIR=/opt/birt-fonts

# System packages
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        openjdk-${JAVA_VERSION}-jre-headless \
        wget \
        unzip \
        fontconfig \
        fonts-dejavu-core \
        fonts-liberation \
        perl \
        zip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Tomcat
RUN mkdir -p ${TOMCAT_HOME} \
    && wget -q "https://archive.apache.org/dist/tomcat/tomcat-${TOMCAT_MAJOR}/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz" -O /tmp/tomcat.tar.gz \
    && tar xzf /tmp/tomcat.tar.gz -C ${TOMCAT_HOME} --strip-components=1 \
    && rm -f /tmp/tomcat.tar.gz

# Original hardening you had
RUN grep -rl --include \*.xml allow . | xargs sed -i 's/allow/deny/g' || true

# Determine BIRT base URL based on channel + install runtime
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
    wget -q "${BIRT_BASE_URL}/${RUNTIME_ZIP}" -O /tmp/"${RUNTIME_ZIP}"; \
    if wget -qO- --spider "${BIRT_BASE_URL}/${RUNTIME_ZIP}.sha512"; then \
      wget -q "${BIRT_BASE_URL}/${RUNTIME_ZIP}.sha512" -O /tmp/"${RUNTIME_ZIP}.sha512"; \
      (cd /tmp && sha512sum -c "${RUNTIME_ZIP}.sha512"); \
    fi; \
    unzip -q /tmp/"${RUNTIME_ZIP}" -d /tmp/birt; \
    rm -rf "${TOMCAT_HOME}/webapps/birt" || true; \
    cp -r /tmp/birt/WebViewerExample "${TOMCAT_HOME}/webapps/birt"; \
    \
    # Prefer the ODA xml addon if present in runtime pack, else fallback URL
    if compgen -G "/tmp/birt/ReportEngine/addons/org.eclipse.datatools.enablement.oda.xml_*.jar" > /dev/null; then \
      cp /tmp/birt/ReportEngine/addons/org.eclipse.datatools.enablement.oda.xml_*.jar "${TOMCAT_HOME}/webapps/birt/WEB-INF/lib/"; \
    else \
      wget -q -O "${TOMCAT_HOME}/webapps/birt/WEB-INF/lib/$(basename ${ODA_XML_JAR_URL})" "${ODA_XML_JAR_URL}" || echo "WARN: ODA XML fallback unavailable (non-fatal)"; \
    fi; \
    rm -rf /tmp/birt /tmp/"${RUNTIME_ZIP}" /tmp/"${RUNTIME_ZIP}.sha512"

# Prepare Tomcat configuration in /etc/tomcat and symlink conf
RUN mkdir -p /etc/tomcat \
    && cp -a ${TOMCAT_HOME}/conf/. /etc/tomcat/ \
    && rm -rf ${TOMCAT_HOME}/conf \
    && ln -s /etc/tomcat ${TOMCAT_HOME}/conf

# Patch server.xml idempotently to respect reverse proxy headers
COPY scripts/patch_server_xml.sh /usr/local/bin/patch_server_xml.sh
RUN chmod +x /usr/local/bin/patch_server_xml.sh \
    && /usr/local/bin/patch_server_xml.sh /etc/tomcat/server.xml

# ---- Fonts: add your custom font, but DO NOT inject Arial.ttf ----
# (Arial will be mapped to Liberation Sans / DejaVu Sans)
RUN set -euo pipefail; \
    mkdir -p "${BIRT_FONTS_DIR}"

ADD mundial.ttf /usr/share/fonts/truetype/mundial.ttf
RUN fc-cache -f >/dev/null 2>&1 || true

# ---- Report files (IMPORTANT: no VOLUME that would hide them) ----
ADD version.rptdesign ${TOMCAT_HOME}/webapps/birt/
ADD version.txt      ${TOMCAT_HOME}/webapps/birt/
ADD index.html       ${TOMCAT_HOME}/webapps/birt/
ADD credix_repayment_schedule.rptdesign ${TOMCAT_HOME}/webapps/birt/

# remove default pages with dangerous information
RUN rm -rf ${TOMCAT_HOME}/webapps/ROOT/index.jsp
ADD error.html ${TOMCAT_HOME}/webapps/ROOT/
COPY web.xml ${TOMCAT_HOME}/webapps/ROOT/WEB-INF/

# CA certs
ADD /cert/*.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates || true

RUN rm -f ${TOMCAT_HOME}/conf/logging.properties || true

# Modify BIRT viewer settings for reports path issues
RUN perl -0777 -i -pe 's|(\<param-name\>\s*BIRT_VIEWER_WORKING_FOLDER\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1/opt/tomcat/webapps/birt/\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml || true
RUN perl -0777 -i -pe 's|(\<param-name\>\s*BIRT_VIEWER_WORKING_FOLDER\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1/opt/tomcat/webapps/birt/\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml || true
RUN perl -0777 -i -pe 's|(\<param-name\>\s*WORKING_FOLDER_ACCESS_ONLY\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1false\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml || true
RUN perl -0777 -i -pe 's|(\<param-name\>\s*WORKING_FOLDER_ACCESS_ONLY\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1false\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml || true

# ---- Patch fontsConfig.xml INSIDE the BIRT runtime JAR (non-OSGi runtime) ----
# This is the reliable approach for non-OSGi packs (unzip jar, change xml, zip back). :contentReference[oaicite:1]{index=1}
RUN set -euo pipefail; \
    LIB_DIR="${TOMCAT_HOME}/webapps/birt/WEB-INF/lib"; \
    test -d "${LIB_DIR}" || (echo "ERROR: ${LIB_DIR} missing" && exit 1); \
    \
    echo "Searching for fontsConfig.xml inside JARs in ${LIB_DIR} ..."; \
    mapfile -t JARS < <(ls -1 "${LIB_DIR}"/*.jar 2>/dev/null || true); \
    if [[ "${#JARS[@]}" -eq 0 ]]; then \
      echo "ERROR: No JARs found in ${LIB_DIR}"; \
      ls -la "${LIB_DIR}" || true; \
      exit 1; \
    fi; \
    \
    FOUND=0; \
    for J in "${JARS[@]}"; do \
      ENTRY="$(unzip -l "$J" 2>/dev/null | awk '{print $4}' | grep -E '(^|/)fontsConfig\.xml$' | head -n1 || true)"; \
      if [[ -n "${ENTRY}" ]]; then \
        echo "Patching ${ENTRY} in: $J"; \
        TMPD="$(mktemp -d)"; \
        unzip -q "$J" "$ENTRY" -d "$TMPD"; \
        FC_XML="$TMPD/$ENTRY"; \
        \
        # Ensure font paths (idempotent)
        if grep -q "<font-paths>" "$FC_XML"; then \
          if ! grep -Fq "path=\"${BIRT_FONTS_DIR}\"" "$FC_XML"; then \
            perl -0777 -i -pe "s|<font-paths>|<font-paths>\\n    <path path=\\\"${BIRT_FONTS_DIR}\\\"/>\\n    <path path=\\\"/usr/share/fonts\\\"/>\\n    <path path=\\\"/usr/share/fonts/truetype\\\"/>\\n    <path path=\\\"/usr/share/fonts/truetype/dejavu\\\"/>\\n    <path path=\\\"/usr/share/fonts/truetype/liberation\\\"/>|s" "$FC_XML"; \
          fi; \
        else \
          perl -0777 -i -pe "s|(<configuration[^>]*>)|\\1\\n  <font-paths>\\n    <path path=\\\"${BIRT_FONTS_DIR}\\\"/>\\n    <path path=\\\"/usr/share/fonts\\\"/>\\n    <path path=\\\"/usr/share/fonts/truetype\\\"/>\\n    <path path=\\\"/usr/share/fonts/truetype/dejavu\\\"/>\\n    <path path=\\\"/usr/share/fonts/truetype/liberation\\\"/>\\n  </font-paths>|s" "$FC_XML"; \
        fi; \
        \
        # Map Arial to a sane Linux font that definitely contains Czech glyphs
        # (BIRT templates often hardcode Arial; we remap it here.)
        if ! grep -Eq "name=\\\"Arial\\\"" "$FC_XML"; then \
          if grep -q "<font-aliases>" "$FC_XML"; then \
            perl -0777 -i -pe 's|<font-aliases>|<font-aliases>\n    <alias name="Arial" font="Liberation Sans"/>\n    <alias name="ArialMT" font="Liberation Sans"/>\n    <alias name="Arial Unicode MS" font="DejaVu Sans"/>|s' "$FC_XML"; \
          else \
            perl -0777 -i -pe 's|(</font-paths>)|$1\n  <font-aliases>\n    <alias name="Arial" font="Liberation Sans"/>\n    <alias name="ArialMT" font="Liberation Sans"/>\n    <alias name="Arial Unicode MS" font="DejaVu Sans"/>\n  </font-aliases>|s' "$FC_XML"; \
          fi; \
        fi; \
        \
        (cd "$TMPD" && zip -q -u "$J" "$ENTRY"); \
        rm -rf "$TMPD"; \
        FOUND=1; \
      fi; \
    done; \
    \
    if [[ "$FOUND" -eq 0 ]]; then \
      echo "ERROR: No fontsConfig.xml found inside any JAR in ${LIB_DIR}"; \
      echo "Hint: list likely candidates:"; \
      ls -1 "${LIB_DIR}" | grep -i font || true; \
      exit 1; \
    fi; \
    echo "fontsConfig.xml patch done."

# One more font cache refresh
RUN fc-cache -f >/dev/null 2>&1 || true

EXPOSE 8080
CMD ["/opt/tomcat/bin/catalina.sh", "run"]
