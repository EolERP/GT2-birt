FROM ubuntu:20.04

# --- Version / constants (keep everything else the same) ---
ARG UBUNTU_VERSION=20.04

ARG JAVA_VERSION=11

ARG TOMCAT_VERSION=9.0.106
ARG TOMCAT_MAJOR=9

ARG BIRT_VERSION=4.13.0
ARG BIRT_DROP=R-R1-4.13.0-202303022006
ARG BIRT_RUNTIME_DATE=20230302

ARG MYSQL_CONNECTOR_VERSION=8.0.15
ARG ODA_XML_JAR_VERSION=1.4.102.201901091730
ARG ODA_XML_RELEASE=2021-03
ARG ODA_XML_RELEASE_BUILD=202103171000

ENV TOMCAT_HOME=/opt/tomcat

#Update
RUN apt-get update
RUN apt-get -y upgrade

#Pre-Installation
RUN apt -y install openjdk-${JAVA_VERSION}-jdk
RUN apt -y install wget
RUN wget "https://archive.apache.org/dist/tomcat/tomcat-${TOMCAT_MAJOR}/v${TOMCAT_VERSION}/bin/apache-tomcat-${TOMCAT_VERSION}.tar.gz" -P ${TOMCAT_HOME}
RUN tar xzvf ${TOMCAT_HOME}/apache-tomcat-${TOMCAT_VERSION}.tar.gz -C ${TOMCAT_HOME} --strip-components=1
RUN rm ${TOMCAT_HOME}/apache-tomcat-${TOMCAT_VERSION}.tar.gz

RUN grep -rl --include \*.xml allow . | xargs sed -i 's/allow/deny/g'

RUN apt -y install unzip
RUN wget "http://download.eclipse.org/birt/downloads/drops/${BIRT_DROP}/birt-runtime-${BIRT_VERSION}-${BIRT_RUNTIME_DATE}.zip" -P ${TOMCAT_HOME}/webapps
RUN unzip "${TOMCAT_HOME}/webapps/birt-runtime-${BIRT_VERSION}-${BIRT_RUNTIME_DATE}.zip" -d ${TOMCAT_HOME}/webapps/birt-runtime
RUN mv "${TOMCAT_HOME}/webapps/birt-runtime/WebViewerExample" "${TOMCAT_HOME}/webapps/birt"
RUN rm ${TOMCAT_HOME}/webapps/birt-runtime-${BIRT_VERSION}-${BIRT_RUNTIME_DATE}.zip
RUN rm -f -r ${TOMCAT_HOME}/webapps/birt-runtime

#RUN mkdir /usr/share/tomcat && mkdir /etc/tomcat
RUN cd ${TOMCAT_HOME} && ln -s /etc/tomcat conf
# RUN ln -s /opt/tomcat/webapps/ /usr/share/tomcat/webapps

#Add JDBC
RUN wget "http://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-${MYSQL_CONNECTOR_VERSION}.tar.gz" -P ${TOMCAT_HOME}/webapps/birt/WEB-INF/lib
RUN tar xzvf "${TOMCAT_HOME}/webapps/birt/WEB-INF/lib/mysql-connector-java-${MYSQL_CONNECTOR_VERSION}.tar.gz" -C ${TOMCAT_HOME}/webapps/birt/WEB-INF/lib/ --strip-components=1 mysql-connector-java-${MYSQL_CONNECTOR_VERSION}/mysql-connector-java-${MYSQL_CONNECTOR_VERSION}.jar
RUN wget "https://download.eclipse.org/releases/${ODA_XML_RELEASE}/${ODA_XML_RELEASE_BUILD}/plugins/org.eclipse.datatools.enablement.oda.xml_${ODA_XML_JAR_VERSION}.jar" -P ${TOMCAT_HOME}/webapps/birt/WEB-INF/lib


# Map Reports folder
VOLUME ${TOMCAT_HOME}/webapps/birt

ADD mundial.ttf /usr/share/fonts/truetype
ADD arial.ttf /usr/share/fonts/truetype

ADD version.rptdesign ${TOMCAT_HOME}/webapps/birt
ADD version.txt ${TOMCAT_HOME}/webapps/birt
ADD index.html ${TOMCAT_HOME}/webapps/birt

# remove default pages with dangerous information
RUN rm -f -r ${TOMCAT_HOME}/webapps/ROOT/index.jsp
ADD error.html ${TOMCAT_HOME}/webapps/ROOT
COPY web.xml ${TOMCAT_HOME}/webapps/ROOT/WEB-INF

ADD /cert/*.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates

RUN rm ${TOMCAT_HOME}/conf/logging.properties

# Modify birt viewer setting for reports path issue
RUN perl -i -p0e "s/BIRT_VIEWER_WORKING_FOLDER<\/param-name>\n\t\t<param-value>/BIRT_VIEWER_WORKING_FOLDER<\/param-name>\n\t\t<param-value>\/opt\/tomcat\/webapps\/birt\//smg" ${TOMCAT_HOME}/webapps/birt/WEB-INF/web.xml

#Start
CMD ["/opt/tomcat/bin/catalina.sh", "run"]

#Port
EXPOSE 8080
