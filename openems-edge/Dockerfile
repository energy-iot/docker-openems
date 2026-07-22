# Use an official Java runtime as a parent image
FROM eclipse-temurin:21

# Set the working directory in the container
WORKDIR /usr/lib/openems

# OpenEMS edge version — tracks latest (see docs/aws-arch-v2-plan.md D1).
# The jar is fetched at build time and sha256-verified, not committed to git.
ARG OPENEMS_EDGE_VERSION=2026.7.0
ARG OPENEMS_EDGE_SHA256=7de6160daadf7883d6930bc29119e28cf13304644fe8c0c40323ac049bfa06d7

RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Download the pinned release jar and verify its checksum before use.
RUN curl -fSL "https://github.com/OpenEMS/openems/releases/download/${OPENEMS_EDGE_VERSION}/openems-edge.jar" -o /usr/lib/openems/openems.jar \
 && echo "${OPENEMS_EDGE_SHA256}  /usr/lib/openems/openems.jar" | sha256sum -c -

RUN mkdir /etc/openems.d

# Set the Java options and start command
CMD ["java", "-Dfelix.cm.dir=/etc/openems.d/", "-jar", "/usr/lib/openems/openems.jar"]
