# nginx-qlog-benchmark

Benchmarking setup for [nginx with qlog support](https://github.com/KasenX/nginx-qlog). Uses Cloudflare's [quiche](https://github.com/cloudflare/quiche) client, and a netem router for network emulation.

## Network topology

```
       WAN_A (10.10.0.0/24)                WAN_B (10.20.0.0/24)
    =========================           =========================
    |                       |           |                       |
    |      [ CLIENT ]       |           |       [ NGINX ]       |
    |    10.10.0.10 (eth0)  |           |    10.20.0.10 (eth0)  |
    |           |           |           |           |           |
    ============|============           ============|============
                |                                   |
                |        [ NETEM ROUTER ]           |
                |          (CPU CORE 4)             |
                |    _______________________        |
                |   |                       |       |
                +---|10.10.0.100 10.20.0.100|-------+
                    |(eth0)           (eth1)|
                    |_______________________|
                                |
                         [ IP FORWARDING ]
```

## Prerequisites

- Docker and Docker Compose
- [mkcert](https://github.com/FiloSottile/mkcert) for TLS certificates
- 5+ CPU cores (services are pinned to cores 0-4)

## Setup

Generate TLS certificates:

```bash
mkcert -install
mkcert -cert-file server.crt -key-file server.key localhost 10.20.0.10
```

## Usage

```bash
CA_PATH=$(mkcert -CAROOT) docker compose up --build -d
```

qlog output is written to the `qlog/` directory.
