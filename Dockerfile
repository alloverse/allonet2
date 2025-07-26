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
RUN swift build -c release -Xswiftc -static-stdlib
RUN cp /app/.build/release/AlloPlace /usr/local/bin/AlloPlace

# Listen on the default AlloPlace HTTP port
EXPOSE 9080/tcp

# Run it! (override with your own flags via `docker run … -- <flags>`)
ENTRYPOINT ["AlloPlace"]