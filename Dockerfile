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
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
RUN wget "https://archive.apache.org/dist/tomcat/tomcat-${TOMCAT_MAJOR}/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz" -P ${TOMCAT_HOME}
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
      else \
        wget -O ${TOMCAT_HOME}/webapps/birt/WEB-INF/lib/$(basename ${ODA_XML_JAR_URL}) "${ODA_XML_JAR_URL}"; \
      fi; \

    rm -f ${TOMCAT_HOME}/webapps/${RUNTIME_ZIP}*; \
    rm -f -r ${TOMCAT_HOME}/webapps/birt-runtime

#RUN mkdir /usr/share/tomcat && mkdir /etc/tomcat
RUN cd ${TOMCAT_HOME} && ln -s /etc/tomcat conf
# RUN ln -s /opt/tomcat/webapps/ /usr/share/tomcat/webapps



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
# Try to set in both web.xml and web-viewer.xml; if not present, append explicit context-params
RUN perl -0777 -i -pe 's|(\<param-name\>\s*BIRT_VIEWER_WORKING_FOLDER\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1/opt/tomcat/webapps/birt/\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml || true
RUN perl -0777 -i -pe 's|(\<param-name\>\s*BIRT_VIEWER_WORKING_FOLDER\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1/opt/tomcat/webapps/birt/\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml || true
RUN perl -0777 -i -pe 's|(\<param-name\>\s*WORKING_FOLDER_ACCESS_ONLY\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1false\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml || true
RUN perl -0777 -i -pe 's|(\<param-name\>\s*WORKING_FOLDER_ACCESS_ONLY\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1false\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml || true
RUN awk 'BEGIN{print=1} {print} /<\/web-app>/{exit}' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml > /tmp/web.xml && \
    {
      echo "  <context-param>";
      echo "    <param-name>BIRT_VIEWER_WORKING_FOLDER</param-name>";
      echo "    <param-value>/opt/tomcat/webapps/birt/</param-value>";
      echo "  </context-param>";
      echo "  <context-param>";
      echo "    <param-name>WORKING_FOLDER_ACCESS_ONLY</param-name>";
      echo "    <param-value>false</param-value>";
      echo "  </context-param>";
      echo "</web-app>";
    } >> /tmp/web.xml && mv /tmp/web.xml ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml
RUN awk 'BEGIN{print=1} {print} /<\/web-app>/{exit}' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml > /tmp/web-viewer.xml && \
    {
      echo "  <context-param>";
      echo "    <param-name>BIRT_VIEWER_WORKING_FOLDER</param-name>";
      echo "    <param-value>/opt/tomcat/webapps/birt/</param-value>";
      echo "  </context-param>";
      echo "  <context-param>";
      echo "    <param-name>WORKING_FOLDER_ACCESS_ONLY</param-name>";
      echo "    <param-value>false</param-value>";
      echo "  </context-param>";
      echo "</web-app>";
    } >> /tmp/web-viewer.xml && mv /tmp/web-viewer.xml ${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml

#Start
CMD ["/opt/tomcat/bin/catalina.sh", "run"]

#Port
EXPOSE 8080
