# fractalsqld for Apache Druid: the reasoning, embedding and enterprise service.
#
# It runs on the same host as the Druid brokers and serves the FractalSQL extension over a
# Unix socket. The reasoning plugin, libcurl and the enterprise library live
# here, so the Druid image stays distroless.
#
#   docker build -f docker/fractalsqld/Dockerfile -t fractalsqld:druid .
#
# The build context is the repository root.

# The daemon's JVM is independent of Druid's: 21 by default; 17 or 25 with --build-arg JAVA_VERSION=17 or 25.
#
# The licensed enterprise library is not part of the repository. Drop it, with its .sig, beside the community core in
# include/<platform>/ and this build picks it up; without it the tier stays off.
ARG JAVA_VERSION=21
FROM eclipse-temurin:${JAVA_VERSION}-jdk AS build
ARG ARCH=linux-x86_64
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libssl-dev python3 \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY include ./include
COPY service ./service
RUN make -C service jvm build/fsqlctl
# The enterprise library and its signature, when they were dropped into include/<platform>/. An empty directory otherwise.
RUN mkdir -p /out/enterprise \
 && cp include/${ARCH}/libfractalsql-enterprise-sovereign-c.so include/${ARCH}/libfractalsql-enterprise-sovereign-c.so.sig /out/enterprise/ 2>/dev/null; true

FROM eclipse-temurin:${JAVA_VERSION}-jre
RUN apt-get update \
 && apt-get install -y --no-install-recommends libcurl4 libssl3 \
 && rm -rf /var/lib/apt/lists/*
ARG ARCH=linux-x86_64
COPY --from=build /src/service/build/jvm/fractalsqld.jar /opt/fractalsql/fractalsqld.jar
COPY --from=build /src/service/build/jvm/libfsqld_jni.so /opt/fractalsql/libfsqld_jni.so
COPY --from=build /src/service/build/fsqlctl /usr/local/bin/fsqlctl
COPY include/${ARCH}/fractalsql-reasoning-http.so include/${ARCH}/fractalsql-reasoning-http.so.sig /opt/fractalsql/
# The enterprise library, when it was dropped beside the core. The .sig must sit beside it.
COPY --from=build /out/enterprise/ /opt/fractalsql/enterprise/
COPY docker/fractalsqld/entrypoint.sh /usr/local/bin/fractalsqld-entrypoint
RUN chmod 0755 /usr/local/bin/fractalsqld-entrypoint \
 && mkdir -p /run/fractalsql /var/lib/fractalsql /opt/fractalsql/enterprise \
 && chown 1000:1000 /run/fractalsql /var/lib/fractalsql
USER 1000:1000
ENTRYPOINT ["/usr/local/bin/fractalsqld-entrypoint"]
