FROM ubuntu:20.04
RUN mkdir -p /opt/openems-backend
WORKDIR /opt/openems-backend
COPY openems-backend.jar ./
COPY config.d ./config.d
COPY openems-backend.sh ./
RUN apt-get update
RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common curl gnupg
RUN curl -sL https://repos.influxdata.com/influxdb.key -o /etc/apt/trusted.gpg.d/influxdb.asc
RUN add-apt-repository -y ppa:openjdk-r/ppa
RUN apt-get install -y openjdk-17-jdk
RUN apt-get install -y openjdk-17-jre
RUN apt-get install -y influxdb
RUN update-alternatives --config java
RUN update-alternatives --config javac
RUN chmod 777 ./openems-backend.sh
USER root
EXPOSE 8075-8082
EXPOSE 5432
ENTRYPOINT ["./openems-backend.sh"]
