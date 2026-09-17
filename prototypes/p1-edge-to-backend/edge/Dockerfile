FROM eclipse-temurin:21-jre-jammy

ARG OPENEMS_VERSION=2026.6.0
WORKDIR /opt/openems-edge

# Prebuilt jar from the official June release (no source build needed)
ADD https://github.com/OpenEMS/openems/releases/download/${OPENEMS_VERSION}/openems-edge.jar ./openems-edge.jar
COPY config.d ./config.d
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# entrypoint renders per-edge config (EDGE_ID, BACKEND_URI) then starts OpenEMS
ENTRYPOINT ["/entrypoint.sh"]
