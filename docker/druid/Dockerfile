# The FractalSQL extension, baked into the Druid image.
#
# The extension JAR is COPIED into the image rather than bind-mounted
# from the host. A bind mount of a file that gets replaced while the
# containers are running truncates it mid-read -- Druid then fails at
# startup with "ZipException: zip file is empty" and every service
# dies. Baking it in removes the race entirely.
#
# The build context is docker/druid, and the freshly built JAR is staged
# at extensions/fractalsql-druid/fractalsql-druid.jar before
# "docker compose build" runs.
#
# The reasoning plugin, libcurl and the enterprise library are NOT in this
# image. They belong to fractalsqld, which runs as its own service, so
# the Druid image stays distroless and dependency-free.

# Druid 37 and 38 are supported; build against 37 with DRUID_VERSION=37.0.0 (docker compose reads FSQL_DRUID_VERSION).
ARG DRUID_VERSION=38.0.0
FROM apache/druid:${DRUID_VERSION}

# ExtensionsLoader treats each entry of druid.extensions.loadList as a
# DIRECTORY and scans it for *.jar, so the JAR goes in a directory named
# after the extension.
COPY extensions/fractalsql-druid/fractalsql-druid.jar \
     /opt/druid/extensions/fractalsql-druid/fractalsql-druid.jar
