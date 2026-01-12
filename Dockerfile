FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Tomcat
ENV TOMCAT_VERSION=9.0.113
ENV TOMCAT_HOME=/opt/tomcat

# BIRT runtime (ověřený název souboru ve "release/4.13.0/downloads")
ENV BIRT_VERSION=4.13.0
ENV BIRT_RUNTIME_ZIP=birt-runtime-4.13.0-20230302.zip
ENV BIRT_URL=https://download.eclipse.org/birt/updates/release/4.13.0/downloads/${BIRT_RUNTIME_ZIP}

# Where we stage fonts for BIRT
ENV BIRT_FONTS_DIR=/opt/birt-fonts

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      openjdk-21-jre-headless \
      wget \
      unzip \
      fontconfig \
      fonts-dejavu-core \
      fonts-dejavu-extra \
      fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# ------------------------------------------------------------
# Install Tomcat
# ------------------------------------------------------------
RUN set -eux; \
    mkdir -p /opt/tomcat; \
    wget -q -O /tmp/tomcat.tar.gz "https://archive.apache.org/dist/tomcat/tomcat-9/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz"; \
    tar xzf /tmp/tomcat.tar.gz -C /opt/tomcat --strip-components=1; \
    rm -f /tmp/tomcat.tar.gz

# ------------------------------------------------------------
# Install BIRT WebViewerExample into Tomcat as /birt
# ------------------------------------------------------------
RUN set -eux; \
    wget -q -O /tmp/birt.zip "${BIRT_URL}"; \
    unzip -q /tmp/birt.zip -d /tmp/birt; \
    rm -rf "${TOMCAT_HOME}/webapps/birt"; \
    cp -r /tmp/birt/WebViewerExample "${TOMCAT_HOME}/webapps/birt"; \
    rm -rf /tmp/birt /tmp/birt.zip

# ------------------------------------------------------------
# Fonts: stage fonts and force predictable BIRT font config
# (to stop random "Arial" variants from dropping Czech glyphs)
# ------------------------------------------------------------
RUN set -eux; \
    mkdir -p "${BIRT_FONTS_DIR}"; \
    \
    # Copy usable fonts into a dedicated dir (and DO NOT bring any custom arial.ttf along)
    cp -f /usr/share/fonts/truetype/*.ttf "${BIRT_FONTS_DIR}/" 2>/dev/null || true; \
    cp -f /usr/share/fonts/truetype/dejavu/*.ttf "${BIRT_FONTS_DIR}/" 2>/dev/null || true; \
    cp -f /usr/share/fonts/truetype/liberation/*.ttf "${BIRT_FONTS_DIR}/" 2>/dev/null || true; \
    rm -f "${BIRT_FONTS_DIR}/arial.ttf" || true; \
    \
    # Ensure WEB-INF/classes exists and put fontsConfig.xml there
    CLASSES_DIR="${TOMCAT_HOME}/webapps/birt/WEB-INF/classes"; \
    mkdir -p "${CLASSES_DIR}"; \
    FC_XML="${CLASSES_DIR}/fontsConfig.xml"; \
    \
    # Write a clean fontsConfig.xml without heredoc shenanigans
    printf '%s\n' \
'<?xml version="1.0" encoding="UTF-8"?>' \
'<configuration>' \
'  <font-paths>' \
'    <path path="/opt/birt-fonts"/>' \
'    <path path="/usr/share/fonts"/>' \
'    <path path="/usr/share/fonts/truetype"/>' \
'    <path path="/usr/share/fonts/truetype/dejavu"/>' \
'    <path path="/usr/share/fonts/truetype/liberation"/>' \
'  </font-paths>' \
'' \
'  <font-aliases>' \
'    <!-- DejaVu Sans: reliable Czech glyph coverage -->' \
'    <alias name="Arial" font="DejaVu Sans"/>' \
'    <alias name="ArialMT" font="DejaVu Sans"/>' \
'    <alias name="Arial Unicode MS" font="DejaVu Sans"/>' \
'  </font-aliases>' \
'</configuration>' \
    > "${FC_XML}"; \
    \
    echo "Generated ${FC_XML}:"; \
    sed -n '1,200p' "${FC_XML}"

# Refresh font cache (deterministic-ish)
RUN fc-cache -f -v

EXPOSE 8080
CMD ["bash", "-lc", "/opt/tomcat/bin/catalina.sh run"]
