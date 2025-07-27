# Dockerfile for running AlloPlace

# ---------- Build stage ------------------------------------------------------
FROM swift:6.1.2-noble AS build

# libdatachannel-dev build dependency
RUN echo "deb http://www.deb-multimedia.org sid main" >> /etc/apt/sources.list && \
    apt-get update -oAcquire::AllowInsecureRepositories=true; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-unauthenticated deb-multimedia-keyring && \
    apt-get update -oAcquire::AllowInsecureRepositories=true && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y libdatachannel-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY . .
RUN swift build -c release -Xswiftc -static-stdlib --product AlloPlace

# ---------- Runtime stage ----------------------------------------------------
FROM ubuntu:24.04

# libdatachannel runtime without dev
RUN echo "deb http://www.deb-multimedia.org sid main" >> /etc/apt/sources.list && \
    apt-get update -oAcquire::AllowInsecureRepositories=true && \
    DEBIAN_FRONTEND=noninteractive \
    apt-get install --allow-unauthenticated -y --no-install-recommends \
        deb-multimedia-keyring \
        libdatachannel0.23 libcurl4  \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Copy the compiled binary and Swift runtime libs from the build stage
COPY --from=build /app/.build/release/AlloPlace /usr/local/bin/AlloPlace
COPY --from=build /usr/lib/swift /usr/lib/swift

# Listen on the default AlloPlace HTTP port
EXPOSE 9080/tcp

ENTRYPOINT ["/usr/local/bin/AlloPlace"]