ARG UBUNTU_VERSION=20.04
FROM ubuntu:${UBUNTU_VERSION}

# --- Version / constants (keep everything else the same) ---

ARG JAVA_VERSION=17

ARG TOMCAT_VERSION=9.0.113
ARG TOMCAT_MAJOR=9

ARG BIRT_VERSION=4.14.0
ARG BIRT_DROP=snapshot
ARG BIRT_RUNTIME_DATE=202306081749


ENV TOMCAT_HOME=/opt/tomcat

# Pre-Installation and system packages
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && apt-get install -y --no-install-recommends \
        openjdk-${JAVA_VERSION}-jre-headless \
        wget \
        unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*
RUN wget "https://archive.apache.org/dist/tomcat/tomcat-${TOMCAT_MAJOR}/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz" -P ${TOMCAT_HOME}
RUN tar xzvf ${TOMCAT_HOME}/apache-tomcat-${TOMCAT_VERSION}.tar.gz -C ${TOMCAT_HOME} --strip-components=1
RUN rm ${TOMCAT_HOME}/apache-tomcat-${TOMCAT_VERSION}.tar.gz

RUN grep -rl --include \*.xml allow . | xargs sed -i 's/allow/deny/g'

RUN wget "https://download.eclipse.org/birt/downloads/drops/${BIRT_DROP}/birt-runtime-${BIRT_VERSION}-${BIRT_RUNTIME_DATE}.zip" -P ${TOMCAT_HOME}/webapps
RUN unzip "${TOMCAT_HOME}/webapps/birt-runtime-${BIRT_VERSION}-${BIRT_RUNTIME_DATE}.zip" -d ${TOMCAT_HOME}/webapps/birt-runtime
RUN mv "${TOMCAT_HOME}/webapps/birt-runtime/WebViewerExample" "${TOMCAT_HOME}/webapps/birt"
RUN rm ${TOMCAT_HOME}/webapps/birt-runtime-${BIRT_VERSION}-${BIRT_RUNTIME_DATE}.zip
RUN rm -f -r ${TOMCAT_HOME}/webapps/birt-runtime

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
# 1) Set it in WEB-INF/web.xml (robust whitespace-insensitive)
RUN perl -0777 -i -pe 's|(\<param-name\>\s*BIRT_VIEWER_WORKING_FOLDER\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1/opt/tomcat/webapps/birt/\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml || true
# 2) Also set it explicitly in WEB-INF/web-viewer.xml (newer packs read from here)
RUN perl -0777 -i -pe 's|(\<param-name\>\s*BIRT_VIEWER_WORKING_FOLDER\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1/opt/tomcat/webapps/birt/\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml || true
# Relax working folder access (some Tomcat 9.0.11x + BIRT combos require it)
RUN perl -0777 -i -pe 's|(\<param-name\>\s*WORKING_FOLDER_ACCESS_ONLY\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1false\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml || true
RUN perl -0777 -i -pe 's|(\<param-name\>\s*WORKING_FOLDER_ACCESS_ONLY\s*\<\/param-name\>\s*\<param-value\>).*?(\<\/param-value\>)|\1false\2|smg' ${TOMCAT_HOME}/webapps/birt/WEB-INF/web-viewer.xml || true

#Start
CMD ["/opt/tomcat/bin/catalina.sh", "run"]

#Port
EXPOSE 8080
