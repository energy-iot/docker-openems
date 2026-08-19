FROM ubuntu:20.04
RUN mkdir -p /opt/openems-backend
WORKDIR /opt/openems-backend

# OpenEMS backend version — pinned to the last monolithic release
# (see docs/aws-arch-v2-plan.md D1). To bump: change these two lines.
# The jar is fetched at build time and sha256-verified, not committed to git.
ARG OPENEMS_BACKEND_VERSION=2026.1.0
ARG OPENEMS_BACKEND_SHA256=f5979cd1015810890a8bd3152c048b7c92f68bab34a59d8dd2b0f00443fbb98f

COPY config.d ./config.d
COPY openems-backend.sh ./

RUN apt-get update && apt-get install -y --no-install-recommends software-properties-common curl gnupg ca-certificates

# Download the pinned release jar and verify its checksum before use.
RUN curl -fSL --retry 3 --retry-delay 2 --retry-connrefused "https://github.com/OpenEMS/openems/releases/download/${OPENEMS_BACKEND_VERSION}/openems-backend.jar" -o openems-backend.jar \
 && echo "${OPENEMS_BACKEND_SHA256}  openems-backend.jar" | sha256sum -c -

RUN apt-get install -y openjdk-21-jdk
RUN apt-get install -y openjdk-21-jre

RUN sed -i 's/\r$//' ./openems-backend.sh && chmod +x ./openems-backend.sh
USER root
EXPOSE 8075-8082
EXPOSE 5432
ENTRYPOINT ["./openems-backend.sh"]
