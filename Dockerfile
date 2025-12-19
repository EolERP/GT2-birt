FROM ubuntu:20.04

#Update
RUN apt-get update
RUN apt-get -y upgrade

#Pre-Installation
RUN apt -y install openjdk-11-jdk
RUN apt -y install wget
RUN wget "https://archive.apache.org/dist/tomcat/tomcat-9/v9.0.106/bin/apache-tomcat-9.0.106.tar.gz" -P /opt/tomcat
RUN tar xzvf /opt/tomcat/apache-tomcat-9*tar.gz -C /opt/tomcat --strip-components=1
RUN rm /opt/tomcat/apache-tomcat-9.0.106.tar.gz

RUN grep -rl --include \*.xml allow . | xargs sed -i 's/allow/deny/g'

RUN apt -y install unzip
RUN wget "http://download.eclipse.org/birt/downloads/drops/R-R1-4.13.0-202303022006/birt-runtime-4.13.0-20230302.zip" -P /opt/tomcat/webapps
RUN unzip "/opt/tomcat/webapps/birt-runtime-4.13.0-20230302.zip" -d /opt/tomcat/webapps/birt-runtime
RUN mv "/opt/tomcat/webapps/birt-runtime/WebViewerExample" "/opt/tomcat/webapps/birt"
RUN rm /opt/tomcat/webapps/birt-runtime-4.13.0-20230302.zip
RUN rm -f -r /opt/tomcat/webapps/birt-runtime


#RUN mkdir /usr/share/tomcat && mkdir /etc/tomcat
RUN cd /opt/tomcat && ln -s /etc/tomcat conf
# RUN ln -s /opt/tomcat/webapps/ /usr/share/tomcat/webapps

#Add JDBC
RUN wget "http://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-8.0.15.tar.gz" -P /opt/tomcat/webapps/birt/WEB-INF/lib
RUN tar xzvf "/opt/tomcat/webapps/birt/WEB-INF/lib/mysql-connector-java-8.0.15.tar.gz" -C /opt/tomcat/webapps/birt/WEB-INF/lib/ --strip-components=1 mysql-connector-java-8.0.15/mysql-connector-java-8.0.15.jar
# XML ODA plugin is provided by the BIRT runtime under WEB-INF/platform/plugins.
# Do not override it with an external jar to avoid version mismatches.


# Map Reports folder
# Remove any built-in OSGi platform to avoid OSGi launch errors in viewer
# Keep WEB-INF/platform so the BIRT runtime can load its bundled ODA plugins.
# Ensure the OSGi framework exists; otherwise, prefer non-OSGi mode by moving plugins to WEB-INF/lib.
# For BIRT 4.13 runtime zip, the platform is complete; do not delete it.

VOLUME /opt/tomcat/webapps/birt

ADD mundial.ttf /usr/share/fonts/truetype
ADD arial.ttf /usr/share/fonts/truetype

ADD version.rptdesign /opt/tomcat/webapps/birt
ADD version.txt /opt/tomcat/webapps/birt
ADD index.html /opt/tomcat/webapps/birt

# remove default pages with dangerous information
RUN rm -f -r /opt/tomcat/webapps/ROOT/index.jsp
ADD error.html /opt/tomcat/webapps/ROOT
COPY web.xml /opt/tomcat/webapps/ROOT/WEB-INF

ADD /cert/*.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates

RUN rm /opt/tomcat/conf/logging.properties

# Modify birt viewer setting for reports path issue
RUN perl -i -p0e "s/BIRT_VIEWER_WORKING_FOLDER<\/param-name>\n\t\t<param-value>/BIRT_VIEWER_WORKING_FOLDER<\/param-name>\n\t\t<param-value>\/opt\/tomcat\/webapps\/birt\//smg" /opt/tomcat/webapps/birt/WEB-INF/web.xml

#Start
CMD ["/opt/tomcat/bin/catalina.sh", "run"]

#Port
EXPOSE 8080
