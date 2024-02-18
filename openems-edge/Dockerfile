# Use an official Java runtime as a parent image
FROM openjdk:17

# Set the working directory in the container
WORKDIR /usr/lib/openems

# Copy the JAR file and configuration directory into the container
COPY ./openems.jar /usr/lib/openems/openems.jar
RUN mkdir /etc/openems.d

# Set the Java options and start command
CMD ["java", "-Dfelix.cm.dir=/etc/openems.d/", "-jar", "/usr/lib/openems/openems.jar"]
