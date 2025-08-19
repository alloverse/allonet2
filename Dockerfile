# Dockerfile for running AlloPlace

ARG SWIFT_VERSION=6.1.2

# ---------- Build stage ------------------------------------------------------
FROM swift:$SWIFT_VERSION AS build

# libdatachannel-dev build dependency
RUN echo "deb http://www.deb-multimedia.org sid main" >> /etc/apt/sources.list && \
    apt-get update -oAcquire::AllowInsecureRepositories=true; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-unauthenticated deb-multimedia-keyring && \
    apt-get update -oAcquire::AllowInsecureRepositories=true && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y libdatachannel-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /place

# Build dependencies as a separate layer
COPY ./Package.* ./
COPY Packages ./Packages
RUN --mount=type=cache,target=/place/.build \
    swift package resolve

COPY . .
RUN --mount=type=cache,target=/place/.build \
    swift build -c debug -Xswiftc -static-stdlib --product AlloPlace && cp .build/debug/AlloPlace .

# ---------- Runtime stage ----------------------------------------------------
FROM swift:$SWIFT_VERSION-slim

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
COPY --from=build /place/AlloPlace /usr/local/bin/AlloPlace
COPY --from=build /usr/lib/swift /usr/lib/swift
COPY Scripts/docker_shim.sh /usr/local/bin/AlloPlaceShim

# Listen on the default AlloPlace HTTP port
EXPOSE 9080/tcp

ENTRYPOINT ["/usr/local/bin/AlloPlaceShim"]