FROM eclipse-temurin:21-jre-jammy

ARG OPENEMS_VERSION=2026.6.0
WORKDIR /opt/openems-backend

# Prebuilt jar from the official June release (no source build needed)
ADD https://github.com/OpenEMS/openems/releases/download/${OPENEMS_VERSION}/openems-backend.jar ./openems-backend.jar
COPY config.d ./config.d

# 8081 = Edge<->Backend websocket, 8082 = UI<->Backend websocket
EXPOSE 8081 8082

ENTRYPOINT ["java", "-XX:+ExitOnOutOfMemoryError", \
  "-Dfelix.cm.dir=/opt/openems-backend/config.d", \
  "-jar", "/opt/openems-backend/openems-backend.jar"]
