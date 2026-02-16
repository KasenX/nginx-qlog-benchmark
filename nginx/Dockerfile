FROM debian:bookworm-slim AS builder

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -qy --no-install-recommends \
    build-essential libpcre2-dev zlib1g zlib1g-dev curl git cmake ninja-build ca-certificates \
 && rm -rf /var/lib/apt/lists/*

COPY --from=golang:latest /usr/local/go/ /usr/local/go/
ENV PATH="/usr/local/go/bin:${PATH}"

RUN git clone --depth=1 https://github.com/google/boringssl.git

WORKDIR /boringssl/build
RUN cmake -GNinja .. && ninja

WORKDIR /
RUN mkdir -p boringssl/.openssl/lib && \
    cp boringssl/build/libcrypto.a boringssl/build/libssl.a boringssl/.openssl/lib && \
    ln -s ../include boringssl/.openssl/include && \
    touch boringssl/.openssl/include/openssl/ssl.h

RUN git clone --depth=1 -b feature/quic-qlog https://github.com/KasenX/nginx-qlog.git

WORKDIR /nginx-qlog
RUN ./auto/configure --prefix=/etc/nginx \
    --build=$(git rev-parse HEAD) \
    --sbin-path=/usr/sbin/nginx \
    --modules-path=/usr/lib/nginx/modules \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --pid-path=/run/nginx.pid \
    --lock-path=/run/nginx.lock \
    --http-client-body-temp-path=/var/cache/nginx/client_temp \
    --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
    --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
    --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
    --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
    --user=nginx \
    --group=nginx \
    --with-compat \
    --with-debug \
    --with-http_ssl_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-cc=c++ \
    --with-cc-opt='-I/boringssl/include -O0 -fno-common -fno-omit-frame-pointer -x c' \
    --with-ld-opt='-L/boringssl/build' \
 && make -j$(nproc) \
 && make install

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends iproute2 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=builder /usr/sbin/nginx /usr/sbin/
COPY --from=builder /etc/nginx /etc/nginx

RUN useradd nginx

RUN mkdir -p /var/log/nginx/qlog /var/cache/nginx /data/sizes && \
    ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log && \
    dd if=/dev/zero of=/data/sizes/1.bin  bs=1M count=1 && \
    dd if=/dev/zero of=/data/sizes/5.bin  bs=1M count=5 && \
    dd if=/dev/zero of=/data/sizes/10.bin bs=1M count=10 && \
    dd if=/dev/zero of=/data/sizes/50.bin bs=1M count=50 && \
    dd if=/dev/zero of=/data/sizes/100.bin bs=1M count=100

COPY nginx.conf /etc/nginx/
COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
