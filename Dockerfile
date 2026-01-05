ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

# --- Version / constants (keep everything else the same) ---

ARG JAVA_VERSION=17

ARG TOMCAT_VERSION=9.0.113
ARG TOMCAT_MAJOR=9

ARG BIRT_VERSION=4.18.0
ARG BIRT_BUILD=202412050604
ARG BIRT_CHANNEL=release
# BIRT base URL will be derived from channel during download (release | latest | milestone)
ARG ODA_XML_JAR_URL=https://download.eclipse.org/releases/2021-03/202103171000/plugins/org.eclipse.datatools.enablement.oda.xml_1.4.102.201901091730.jar


ENV TOMCAT_HOME=/opt/tomcat

# Pre-Installation and system packages
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        openjdk-${JAVA_VERSION}-jre-headless \
        wget \
        unzip \
        xmlstarlet \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
RUN wget --tries=5 --waitretry=5 --timeout=30 --retry-connrefused "https://archive.apache.org/dist/tomcat/tomcat-${TOMCAT_MAJOR}/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz" -P ${TOMCAT_HOME}
RUN tar xzvf ${TOMCAT_HOME}/apache-tomcat-${TOMCAT_VERSION}.tar.gz -C ${TOMCAT_HOME} --strip-components=1
RUN rm ${TOMCAT_HOME}/apache-tomcat-${TOMCAT_VERSION}.tar.gz

# NOTE: Removed legacy global XML 'allow'->'deny' replacement as it breaks BIRT 4.18 viewer config
# RUN grep -rl --include \*.xml allow . | xargs sed -i 's/allow/deny/g'

# Determine BIRT base URL based on channel
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
      elif compgen -G "${TOMCAT_HOME}/webapps/birt-runtime/ReportEngine/plugins/org.eclipse.datatools.enablement.oda.xml_*.jar" > /dev/null; then \
        cp ${TOMCAT_HOME}/webapps/birt-runtime/ReportEngine/plugins/org.eclipse.datatools.enablement.oda.xml_*.jar ${TOMCAT_HOME}/webapps/birt/WEB-INF/lib/; \
      else \
        echo "[WARN] XML ODA plugin not bundled; skipping external download"; \
      fi; \
    # Ensure Flatfile ODA plugin required by version.rptdesign \
    if compgen -G "${TOMCAT_HOME}/webapps/birt-runtime/ReportEngine/addons/org.eclipse.datatools.enablement.oda.flatfile_*.jar" > /dev/null; then \
        cp ${TOMCAT_HOME}/webapps/birt-runtime/ReportEngine/addons/org.eclipse.datatools.enablement.oda.flatfile_*.jar ${TOMCAT_HOME}/webapps/birt/WEB-INF/lib/; \
      else \
        if wget -qO- --spider "https://download.eclipse.org/releases/2021-03/202103171000/plugins/org.eclipse.datatools.enablement.oda.flatfile_1.4.102.201901091730.jar"; then \
          wget -O ${TOMCAT_HOME}/webapps/birt/WEB-INF/lib/org.eclipse.datatools.enablement.oda.flatfile_1.4.102.201901091730.jar "https://download.eclipse.org/releases/2021-03/202103171000/plugins/org.eclipse.datatools.enablement.oda.flatfile_1.4.102.201901091730.jar"; \
        else \
          echo "[WARN] Flatfile ODA plugin not bundled and external URL unavailable; skipping"; \
        fi; \
      fi; \
    # Set viewer working folder to absolute documents directory for deterministic resolution on 4.18+
    xmlstarlet ed -L -u "//context-param[param-name='BIRT_VIEWER_WORKING_FOLDER']/param-value" -v "${TOMCAT_HOME}/webapps/birt/documents" ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml; \
    xmlstarlet ed -L -u "//context-param[param-name='BIRT_VIEWER_WORKING_FOLDER']/param-value" -v "${TOMCAT_HOME}/webapps/birt/documents" ${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml || true; \
    # Enforce viewer working folder and access-only flags deterministically (insert if missing, update if present) \
    for f in "${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml" "${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml"; do \
      [ -f "$f" ] || continue; \
      echo "[birt-config] Processing $f"; \
      # BIRT_VIEWER_WORKING_FOLDER -> ${TOMCAT_HOME}/webapps/birt/documents \
      if xmlstarlet sel -t -v "count(//*[local-name()='context-param'][*[local-name()='param-name']='BIRT_VIEWER_WORKING_FOLDER'])" "$f" | grep -q '^[1-9]'; then \
        xmlstarlet ed -L -u "//*[local-name()='context-param'][*[local-name()='param-name']='BIRT_VIEWER_WORKING_FOLDER']/*[local-name()='param-value']" -v "${TOMCAT_HOME}/webapps/birt/documents" "$f"; \
      else \
        xmlstarlet ed -L \
          -s "/*[local-name()='web-app']" -t elem -n "context-param" -v "" \
          -s "/*[local-name()='web-app']/*[local-name()='context-param'][last()]" -t elem -n "param-name" -v "BIRT_VIEWER_WORKING_FOLDER" \
          -s "/*[local-name()='web-app']/*[local-name()='context-param'][last()]" -t elem -n "param-value" -v "${TOMCAT_HOME}/webapps/birt/documents" \
          "$f"; \
      fi; \
      # WORKING_FOLDER_ACCESS_ONLY -> false (unify across configs) \
      if xmlstarlet sel -t -v "count(//*[local-name()='context-param'][*[local-name()='param-name']='WORKING_FOLDER_ACCESS_ONLY'])" "$f" | grep -q '^[1-9]'; then \
        xmlstarlet ed -L -u "//*[local-name()='context-param'][*[local-name()='param-name']='WORKING_FOLDER_ACCESS_ONLY']/*[local-name()='param-value']" -v "false" "$f"; \
      else \
        xmlstarlet ed -L \
          -s "/*[local-name()='web-app']" -t elem -n "context-param" -v "" \
          -s "/*[local-name()='web-app']/*[local-name()='context-param'][last()]" -t elem -n "param-name" -v "WORKING_FOLDER_ACCESS_ONLY" \
          -s "/*[local-name()='web-app']/*[local-name()='context-param'][last()]" -t elem -n "param-value" -v "false" \
          "$f"; \
      fi; \
    done; \


    rm -f ${TOMCAT_HOME}/webapps/${RUNTIME_ZIP}*; \
    rm -f -r ${TOMCAT_HOME}/webapps/birt-runtime;
    # Keep default viewer config; resolve __report relative to webapp root

#RUN mkdir /usr/share/tomcat && mkdir /etc/tomcat
RUN cd ${TOMCAT_HOME} && ln -s /etc/tomcat conf
# RUN ln -s /opt/tomcat/webapps/ /usr/share/tomcat/webapps



# Map Reports folder
VOLUME ${TOMCAT_HOME}/webapps/birt

ADD mundial.ttf /usr/share/fonts/truetype
ADD arial.ttf /usr/share/fonts/truetype

# Ensure known-good baseline: also place reports into 'documents' working folder
RUN mkdir -p ${TOMCAT_HOME}/webapps/birt/report ${TOMCAT_HOME}/webapps/birt/documents
ADD version.rptdesign ${TOMCAT_HOME}/webapps/birt/report
ADD version.txt ${TOMCAT_HOME}/webapps/birt/report
ADD index.html ${TOMCAT_HOME}/webapps/birt/report
ADD credix_repayment_schedule.rptdesign ${TOMCAT_HOME}/webapps/birt/report
# Primary for 4.18+: documents
ADD version.rptdesign ${TOMCAT_HOME}/webapps/birt/documents
ADD version.txt ${TOMCAT_HOME}/webapps/birt/documents
ADD index.html ${TOMCAT_HOME}/webapps/birt/documents
ADD credix_repayment_schedule.rptdesign ${TOMCAT_HOME}/webapps/birt/documents

# remove default pages with dangerous information
RUN rm -f -r ${TOMCAT_HOME}/webapps/ROOT/index.jsp
ADD error.html ${TOMCAT_HOME}/webapps/ROOT
COPY web.xml ${TOMCAT_HOME}/webapps/ROOT/WEB-INF

ADD /cert/*.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates

RUN rm ${TOMCAT_HOME}/conf/logging.properties

# Use default BIRT viewer configuration; working/resource folders are provided via request params in verification script

#Start
CMD ["/opt/tomcat/bin/catalina.sh", "run"]

#Port
EXPOSE 8080
