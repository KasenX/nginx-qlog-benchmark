# Stage 1: Build quiche tools
FROM rust:1.93-slim-bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    cmake \
    make \
    pkg-config \
    g++ \
    clang \
    libclang-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone --recursive https://github.com/cloudflare/quiche.git

WORKDIR /src/quiche
RUN cargo build --examples --release --features qlog

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    iproute2 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/quiche/target/release/examples/http3-client /usr/local/bin/quiche-client

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
