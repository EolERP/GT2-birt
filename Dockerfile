# syntax=docker/dockerfile:1

# --- Base ---
ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

# --- Versions / constants ---
ARG JAVA_VERSION=21

ARG TOMCAT_VERSION=9.0.113
ARG TOMCAT_MAJOR=9

# BIRT runtime "latest" currently points to 4.22.0 build 202512100727
ARG BIRT_VERSION=4.22.0
ARG BIRT_BUILD=202512100727

# Eclipse DTP XML ODA runtime driver (if you use XML ODA datasources)
ARG ODA_XML_RELEASE=2025-06
ARG ODA_XML_RELEASE_BUILD=202506111000
ARG ODA_XML_JAR_VERSION=1.6.0.202411281604

ENV TOMCAT_HOME=/opt/tomcat

# BIRT 4.21+ on Tomcat requires this add-opens (and you already run with a pile of add-opens anyway)
ENV CATALINA_OPTS="--add-opens=java.base/java.net=ALL-UNNAMED"

# --- OS deps ---
RUN apt-get update && \
    apt-get -y upgrade && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates \
      wget \
      unzip \
      perl \
      fontconfig \
      openjdk-${JAVA_VERSION}-jdk-headless && \
    rm -rf /var/lib/apt/lists/*

# --- Tomcat ---
RUN mkdir -p ${TOMCAT_HOME} && \
    wget -O /tmp/tomcat.tar.gz \
      "https://dlcdn.apache.org/tomcat/tomcat-${TOMCAT_MAJOR}/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz" && \
    tar xzvf /tmp/tomcat.tar.gz -C ${TOMCAT_HOME} --strip-components=1 && \
    rm -f /tmp/tomcat.tar.gz

# Keep your symlink behavior (even though it's a bit… optimistic)
RUN ln -s /etc/tomcat ${TOMCAT_HOME}/conf

# --- BIRT runtime (WebViewerExample -> /birt) ---
RUN wget -O /tmp/birt-runtime.zip \
      "https://download.eclipse.org/birt/updates/release/${BIRT_VERSION}/downloads/birt-runtime-${BIRT_VERSION}-${BIRT_BUILD}.zip" && \
    unzip /tmp/birt-runtime.zip -d ${TOMCAT_HOME}/webapps/birt-runtime && \
    mv ${TOMCAT_HOME}/webapps/birt-runtime/WebViewerExample ${TOMCAT_HOME}/webapps/birt && \
    rm -f /tmp/birt-runtime.zip && \
    rm -rf ${TOMCAT_HOME}/webapps/birt-runtime

# --- Optional: XML ODA driver jar (remove this block if you don't use XML datasources) ---
RUN wget -O ${TOMCAT_HOME}/webapps/birt/WEB-INF/lib/org.eclipse.datatools.enablement.oda.xml_${ODA_XML_JAR_VERSION}.jar \
      "https://download.eclipse.org/releases/${ODA_XML_RELEASE}/${ODA_XML_RELEASE_BUILD}/plugins/org.eclipse.datatools.enablement.oda.xml_${ODA_XML_JAR_VERSION}.jar"

# Map Reports folder
VOLUME ${TOMCAT_HOME}/webapps/birt

# Fonts (as you had)
ADD mundial.ttf /usr/share/fonts/truetype/
ADD arial.ttf   /usr/share/fonts/truetype/

# Your report + data
ADD version.rptdesign ${TOMCAT_HOME}/webapps/birt/
ADD version.txt       ${TOMCAT_HOME}/webapps/birt/
ADD index.html        ${TOMCAT_HOME}/webapps/birt/

# Remove default pages with dangerous information
RUN rm -rf ${TOMCAT_HOME}/webapps/ROOT/index.jsp
ADD error.html ${TOMCAT_HOME}/webapps/ROOT/
COPY web.xml   ${TOMCAT_HOME}/webapps/ROOT/WEB-INF/

# Certificates
ADD /cert/*.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates

# Drop tomcat default logging.properties (your choice)
RUN rm -f ${TOMCAT_HOME}/conf/logging.properties

# Modify birt viewer setting for reports path issue
RUN perl -i -p0e "s/BIRT_VIEWER_WORKING_FOLDER<\/param-name>\n\t\t<param-value>/BIRT_VIEWER_WORKING_FOLDER<\/param-name>\n\t\t<param-value>\/opt\/tomcat\/webapps\/birt\//smg" \
    ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml

# Start
EXPOSE 8080
CMD ["/opt/tomcat/bin/catalina.sh", "run"]
